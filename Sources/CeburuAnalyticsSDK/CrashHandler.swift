import Darwin
import Foundation

// Captures Swift-native crashes — fatalError(), force-unwrap nil, SIGSEGV, SIGBUS, etc.
// NSSetUncaughtExceptionHandler only catches Objective-C NSExceptions; signals cover the rest.
//
// Design: the file is pre-created and pre-opened in install() using Foundation (safe context).
// The signal handler only calls async-signal-safe Darwin functions: backtrace(), gettimeofday(),
// write(), lseek(). No malloc, no Objective-C, no Swift runtime allocations inside the handler.

/// Low-level POSIX signal crash reporter.
///
/// Installs C signal handlers for `SIGABRT`, `SIGSEGV`, `SIGBUS`, `SIGILL`, and `SIGFPE`.
/// When a signal fires, the handler captures a raw backtrace and writes a compact binary
/// `.sigseg` file using only async-signal-safe Darwin syscalls. On the next app launch,
/// ``EncryptedStore/importSignalCrashRecords(sessionId:)`` reads and symbolicates the file,
/// converts it to a `fatal`-severity event, and delivers it to the collector.
///
/// **Async-signal-safety**: The signal handler (`handle(_:)`) never calls `malloc`, Objective-C,
/// or any Swift runtime function. All mutable state it touches (`frameBuffer`, `pendingFd`,
/// `sessionIdCStr`, `exceptionAlreadyCaptured`) is pre-allocated in `install()` and never
/// reallocated while handlers are active.
enum SignalCrashHandler {

    // Populated in install() before any signal fires — never reallocated after.
    nonisolated(unsafe) static var sessionIdCStr: [CChar] = []
    nonisolated(unsafe) static var frameBuffer = [UnsafeMutableRawPointer?](repeating: nil, count: 32)

    // Pre-opened file descriptor — avoids open()/snprintf() inside the signal handler.
    nonisolated(unsafe) static var pendingFd: Int32 = -1
    nonisolated(unsafe) static var pendingPath: String = ""

    // NSException handler sets this before the runtime raises SIGABRT, preventing
    // a second crash record being written for the same crash event.
    nonisolated(unsafe) static var exceptionAlreadyCaptured = false

    private static let monitoredSignals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE]

    // MARK: - Install / Uninstall

    /// Installs POSIX signal handlers and pre-opens the crash file for the handler to write into.
    ///
    /// Must be called from a Foundation context (not from a signal handler).
    /// Pre-opens a `.sigseg` file in the crash directory with `dup()` so the file descriptor
    /// stays valid even if the `FileHandle` object is released. The handler writes into this fd.
    ///
    /// Safe to call multiple times — closes any fd left from a previous install first.
    ///
    /// - Parameters:
    ///   - crashDir:  Directory where the `.sigseg` file is written. Must already exist.
    ///   - sessionId: The current session ID, stored as a C string for async-signal-safe access.
    static func install(crashDir: URL, sessionId: String) {
        sessionIdCStr = sessionId.cString(using: .utf8) ?? []

        // Close any fd left over from a previous install() call.
        if pendingFd >= 0 { Darwin.close(pendingFd); pendingFd = -1 }

        let path = crashDir.appendingPathComponent("pending_signal.sigseg").path
        pendingPath = path

        // Create or truncate the pending crash file using Foundation (safe here).
        FileManager.default.createFile(atPath: path, contents: Data(),
                                       attributes: [.posixPermissions: 0o600])

        // Truncate to zero before duplicating the fd. A previous crash may have written
        // more bytes than the current one will — truncating here (normal context, not
        // signal handler) ensures no stale tail bytes remain. ftruncate is not
        // async-signal-safe so it cannot be called inside the signal handler itself.
        if let fh = FileHandle(forWritingAtPath: path) {
            try? fh.truncate(atOffset: 0)
            pendingFd = dup(fh.fileDescriptor)
        }

        let handler: @convention(c) (Int32) -> Void = { sig in SignalCrashHandler.handle(sig) }
        monitoredSignals.forEach { Darwin.signal($0, handler) }
    }

    /// Restores default signal handlers and closes the pre-opened crash file descriptor.
    ///
    /// Called by ``CeburuAnalyticsSDK/shutdown()``. Also removes the empty placeholder
    /// `.sigseg` file — this path is only reached on a clean shutdown, not after a crash,
    /// so the placeholder is safe to delete.
    static func uninstall() {
        monitoredSignals.forEach { Darwin.signal($0, SIG_DFL) }
        if pendingFd >= 0 { Darwin.close(pendingFd); pendingFd = -1 }
        // Remove the empty placeholder — only reached on clean shutdown, not after a crash.
        if !pendingPath.isEmpty {
            try? FileManager.default.removeItem(atPath: pendingPath)
            pendingPath = ""
        }
    }

    // MARK: - Signal handler (async-signal-safe context only)

    /// The C-convention signal handler — called by the OS on the crashing thread.
    ///
    /// **Must only call async-signal-safe functions.** Specifically: `backtrace()`,
    /// `gettimeofday()`, `write()`, `lseek()`, `raise()`, and `Darwin.signal()`.
    /// Never calls `malloc`, Objective-C, Swift runtime functions, or `NSLog`.
    ///
    /// - Parameter sig: The signal number that fired.
    private static func handle(_ sig: Int32) {
        Darwin.signal(sig, SIG_DFL)

        // NSException handler fires first then raises SIGABRT — skip to avoid duplicate report.
        if sig == SIGABRT && exceptionAlreadyCaptured { raise(sig); return }

        let fd = pendingFd
        guard fd >= 0 else { raise(sig); return }

        // backtrace() is async-signal-safe on Apple platforms.
        let frameCount = frameBuffer.withUnsafeMutableBufferPointer { ptr in
            backtrace(ptr.baseAddress, Int32(ptr.count))
        }

        var tv = timeval()
        gettimeofday(&tv, nil)

        // Seek to start in case this handler fires more than once (defensive).
        _ = Darwin.lseek(fd, 0, SEEK_SET)

        writeCrashFile(fd: fd, sig: sig,
                       tsMs: Int64(tv.tv_sec) * 1000,
                       frameCount: Int(frameCount))

        // Re-raise with default handler so the OS writes its crash log and debugger breaks.
        raise(sig)
    }

    // MARK: - Binary crash writer (signal-safe — no allocations)

    // File format:
    //   magic       UInt32   0x4D534947 ("MSIG")
    //   signal      Int32
    //   timestampMs Int64
    //   sessionLen  UInt16   (includes null terminator)
    //   sessionId   [CChar]  (sessionLen bytes)
    //   frameCount  UInt16
    //   frames      [UInt64] (frameCount addresses)

    /// Writes the binary crash record to `fd` using only `write()` and `lseek()`.
    ///
    /// All fields are written in the host byte order (little-endian on all current Apple hardware).
    /// The reader in ``EncryptedStore/parseSignalCrash(data:fallbackSessionId:)`` uses
    /// `loadUnaligned(fromByteOffset:as:)` which handles any alignment.
    ///
    /// - Parameters:
    ///   - fd:         Pre-opened file descriptor for the `.sigseg` file.
    ///   - sig:        Signal number (e.g. `SIGSEGV`).
    ///   - tsMs:       Crash timestamp in milliseconds since Unix epoch.
    ///   - frameCount: Number of valid entries in `frameBuffer`.
    private static func writeCrashFile(fd: Int32, sig: Int32, tsMs: Int64, frameCount: Int) {
        var magic: UInt32 = 0x4D534947
        withUnsafeBytes(of: &magic)  { _ = Darwin.write(fd, $0.baseAddress, $0.count) }

        var sigVal = sig
        withUnsafeBytes(of: &sigVal) { _ = Darwin.write(fd, $0.baseAddress, $0.count) }

        var ts = tsMs
        withUnsafeBytes(of: &ts)     { _ = Darwin.write(fd, $0.baseAddress, $0.count) }

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
