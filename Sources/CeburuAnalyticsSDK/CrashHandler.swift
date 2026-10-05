import Darwin
import Foundation

// Captures Swift-native crashes — fatalError(), force-unwrap nil, SIGSEGV, SIGBUS, SIGTRAP, etc.
// NSSetUncaughtExceptionHandler only catches Objective-C NSExceptions; signals cover the rest.
//
// Design: the file is pre-created and pre-opened in install() using Foundation (safe context).
// The signal handler only calls async-signal-safe Darwin functions: backtrace(), gettimeofday(),
// _dyld_get_image_vmaddr_slide(), write(), lseek(). No malloc, no Objective-C, no Swift runtime
// allocations inside the handler.

/// Low-level POSIX signal crash reporter.
///
/// Installs C signal handlers for `SIGABRT`, `SIGSEGV`, `SIGBUS`, `SIGILL`, `SIGFPE`,
/// and `SIGTRAP`. When a signal fires, the handler captures a raw backtrace **and the
/// current ASLR slide** and writes a compact binary `.sigseg` file using only
/// async-signal-safe Darwin syscalls. On the next app launch,
/// ``EncryptedStore/importSignalCrashRecords(sessionId:)`` reads the file, adjusts the
/// saved PC addresses for the new ASLR slide, and symbolicates them with `dladdr`.
///
/// **Why SIGTRAP**: Swift traps (force-unwrap nil, out-of-range index, `fatalError()` with
/// optimisations enabled) can raise `SIGTRAP` on some compiler/OS combinations in addition
/// to `SIGABRT`. Adding it here ensures those crashes are never silently lost.
///
/// **Async-signal-safety**: The signal handler (`handle(_:)`) never calls `malloc`,
/// Objective-C, or any Swift runtime function. All mutable state it touches
/// (`frameBuffer`, `pendingFd`, `sessionIdCStr`) is pre-allocated in `install()`.
enum SignalCrashHandler {

    nonisolated(unsafe) static var sessionIdCStr: [CChar] = []
    nonisolated(unsafe) static var frameBuffer = [UnsafeMutableRawPointer?](repeating: nil, count: 32)

    nonisolated(unsafe) static var pendingFd: Int32 = -1
    nonisolated(unsafe) static var pendingPath: String = ""

    // Pre-captured ASLR slide for the main image (index 0).
    // Captured once in install() via dlsym so the signal handler never needs to call
    // _dyld_get_image_vmaddr_slide itself — the symbol is not exported from the Darwin
    // module in newer Xcode/SDK versions and is also not async-signal-safe to look up.
    nonisolated(unsafe) static var capturedAslrSlide: Int64 = 0

    // NSException handler sets this before the runtime raises SIGABRT, preventing
    // a second crash record being written for the same crash event.
    nonisolated(unsafe) static var exceptionAlreadyCaptured = false

    // H-1 fix: added SIGTRAP — Swift traps (force-unwrap, fatalError, out-of-range)
    // raise SIGTRAP on some compiler/OS combinations.
    private static let monitoredSignals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP]

    // MARK: - Install / Uninstall

    static func install(crashDir: URL, sessionId: String) {
        sessionIdCStr = sessionId.cString(using: .utf8) ?? []

        if pendingFd >= 0 { Darwin.close(pendingFd); pendingFd = -1 }

        let path = crashDir.appendingPathComponent("pending_signal.sigseg").path
        pendingPath = path

        FileManager.default.createFile(atPath: path, contents: Data(),
                                       attributes: [.posixPermissions: 0o600])

        if let fh = FileHandle(forWritingAtPath: path) {
            try? fh.truncate(atOffset: 0)
            pendingFd = dup(fh.fileDescriptor)
        }

        // Capture ASLR slide for main image (index 0) at install time (safe context).
        // _dyld_get_image_vmaddr_slide is resolved via dlsym because it is not re-exported
        // from the Darwin Swift module in Xcode 26+ SDKs. The value is fixed for the
        // process lifetime so a single capture here is sufficient.
        typealias SlideFunc = @convention(c) (UInt32) -> Int
        if let sym = dlsym(dlopen(nil, RTLD_LAZY), "_dyld_get_image_vmaddr_slide") {
            capturedAslrSlide = Int64(unsafeBitCast(sym, to: SlideFunc.self)(0))
        }

        let handler: @convention(c) (Int32) -> Void = { sig in SignalCrashHandler.handle(sig) }
        monitoredSignals.forEach { Darwin.signal($0, handler) }
    }

    static func uninstall() {
        monitoredSignals.forEach { Darwin.signal($0, SIG_DFL) }
        if pendingFd >= 0 { Darwin.close(pendingFd); pendingFd = -1 }
        if !pendingPath.isEmpty {
            try? FileManager.default.removeItem(atPath: pendingPath)
            pendingPath = ""
        }
    }

    // MARK: - Signal handler (async-signal-safe context only)

    private static func handle(_ sig: Int32) {
        Darwin.signal(sig, SIG_DFL)

        if sig == SIGABRT && exceptionAlreadyCaptured { raise(sig); return }

        let fd = pendingFd
        guard fd >= 0 else { raise(sig); return }

        let frameCount = frameBuffer.withUnsafeMutableBufferPointer { ptr in
            backtrace(ptr.baseAddress, Int32(ptr.count))
        }

        var tv = timeval()
        gettimeofday(&tv, nil)

        // H-2 fix: read the ASLR slide pre-captured in install() — async-signal-safe read
        // of a pre-allocated static; no allocation, no dyld lookup in the signal handler.
        let slide = capturedAslrSlide

        _ = Darwin.lseek(fd, 0, SEEK_SET)

        writeCrashFile(fd: fd, sig: sig,
                       tsMs:       Int64(tv.tv_sec) * 1000,
                       slide:      slide,
                       frameCount: Int(frameCount))

        raise(sig)
    }

    // MARK: - Binary crash writer (signal-safe — no allocations)

    // File format (all fields little-endian / host byte order):
    //   magic       UInt32   0x4D534947 ("MSIG")
    //   signal      Int32
    //   timestampMs Int64
    //   aslrSlide   Int64    ASLR slide of main executable at crash time (H-2)
    //   sessionLen  UInt16   (includes null terminator)
    //   sessionId   [CChar]  (sessionLen bytes, null-terminated)
    //   frameCount  UInt16
    //   frames      [UInt64] (frameCount raw PC addresses)

    private static func writeCrashFile(fd: Int32, sig: Int32, tsMs: Int64,
                                       slide: Int64, frameCount: Int) {
        var magic: UInt32 = 0x4D534947
        withUnsafeBytes(of: &magic)  { _ = Darwin.write(fd, $0.baseAddress, $0.count) }

        var sigVal = sig
        withUnsafeBytes(of: &sigVal) { _ = Darwin.write(fd, $0.baseAddress, $0.count) }

        var ts = tsMs
        withUnsafeBytes(of: &ts)     { _ = Darwin.write(fd, $0.baseAddress, $0.count) }

        // H-2: write ASLR slide so the reader can adjust addresses on next launch.
        var sl = slide
        withUnsafeBytes(of: &sl)     { _ = Darwin.write(fd, $0.baseAddress, $0.count) }

        var sessionLen = UInt16(sessionIdCStr.count)
        withUnsafeBytes(of: &sessionLen) { _ = Darwin.write(fd, $0.baseAddress, $0.count) }
        sessionIdCStr.withUnsafeBufferPointer { _ = Darwin.write(fd, $0.baseAddress, $0.count) }

        var fc = UInt16(frameCount)
        withUnsafeBytes(of: &fc) { _ = Darwin.write(fd, $0.baseAddress, $0.count) }

        frameBuffer.withUnsafeBufferPointer { buf in
            for i in 0..<min(frameCount, 32) {
                var addr = UInt64(UInt(bitPattern: buf[i]))
                withUnsafeBytes(of: &addr) { _ = Darwin.write(fd, $0.baseAddress, $0.count) }
            }
        }
    }
}