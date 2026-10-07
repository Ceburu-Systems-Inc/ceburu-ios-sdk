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

    // Pre-captured ASLR slide for the main image (index 0) — kept as fallback.
    nonisolated(unsafe) static var capturedAslrSlide: Int64 = 0

    // H-2: per-image registry captured at install() (safe context).
    // Signal handler reads these arrays to find the correct per-frame slide without
    // any dyld calls or allocations at crash time. 512 covers any realistic app.
    nonisolated(unsafe) static var imageBaseAddrs  = [UInt64](repeating: 0, count: 512)
    nonisolated(unsafe) static var imageAslrSlides = [Int64](repeating: 0, count: 512)
    nonisolated(unsafe) static var imageCapturedCount: Int32 = 0

    // NSException handler sets this before the runtime raises SIGABRT, preventing
    // a second crash record being written for the same crash event.
    nonisolated(unsafe) static var exceptionAlreadyCaptured = false

    // I4: previous sigaction saved per signal so we can chain to Crashlytics/Sentry/etc.
    // Count must equal monitoredSignals.count (6). Written once in install(); read in
    // handle() and uninstall() — both sigaction-safe or normal contexts.
    nonisolated(unsafe) static var previousActions: [Darwin.sigaction] = Array(repeating: Darwin.sigaction(), count: 6)
    nonisolated(unsafe) static var isInstalled = false

    // H-1 fix: added SIGTRAP — Swift traps (force-unwrap, fatalError, out-of-range)
    // raise SIGTRAP on some compiler/OS combinations.
    private static let monitoredSignals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP]

    // MARK: - Install / Uninstall

    static func install(crashDir: URL, sessionId: String) {
        sessionIdCStr = sessionId.cString(using: .utf8) ?? []

        if pendingFd >= 0 { Darwin.close(pendingFd); pendingFd = -1 }

        let path = crashDir.appendingPathComponent("pending_signal.sigseg").path
        pendingPath = path

        // I10: AFKU lets the signal handler write to this pre-opened fd even while the device is
        // locked — completeFileProtection would revoke the key on lock, making the write silently fail.
        FileManager.default.createFile(atPath: path, contents: Data(),
                                       attributes: [
                                           .posixPermissions: 0o600,
                                           .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
                                       ])

        if let fh = FileHandle(forWritingAtPath: path) {
            try? fh.truncate(atOffset: 0)
            pendingFd = dup(fh.fileDescriptor)
        }

        // H-2: capture base address and ASLR slide for every loaded image at install time
        // (safe context). The signal handler only reads these arrays — no dyld calls at
        // crash time. All three dyld symbols resolved via dlsym — none of them are
        // re-exported from the Darwin Swift module in Xcode 26+ iOS Simulator SDKs.
        typealias SlideFunc  = @convention(c) (UInt32) -> Int
        typealias CountFunc  = @convention(c) () -> UInt32
        typealias HeaderFunc = @convention(c) (UInt32) -> UnsafeRawPointer?
        let dyldHandle = dlopen(nil, RTLD_LAZY)
        if let slideSym  = dlsym(dyldHandle, "_dyld_get_image_vmaddr_slide"),
           let countSym  = dlsym(dyldHandle, "_dyld_image_count"),
           let headerSym = dlsym(dyldHandle, "_dyld_get_image_header") {
            let slideFunc  = unsafeBitCast(slideSym,  to: SlideFunc.self)
            let countFunc  = unsafeBitCast(countSym,  to: CountFunc.self)
            let headerFunc = unsafeBitCast(headerSym, to: HeaderFunc.self)
            let total = Int(countFunc())
            let n     = min(total, 512)
            for i in 0..<n {
                if let header = headerFunc(UInt32(i)) {
                    imageBaseAddrs[i]  = UInt64(UInt(bitPattern: header))
                    imageAslrSlides[i] = Int64(slideFunc(UInt32(i)))
                }
            }
            imageCapturedCount = Int32(n)
            capturedAslrSlide  = n > 0 ? imageAslrSlides[0] : 0
        }

        // I4: install with sigaction (not signal()) so any previously installed handler
        // (Crashlytics, Sentry, …) is saved and chained after we write our crash file.
        // Guard against double-install: if called again for a session refresh, only the
        // file/session fields above need updating — we must not overwrite previousActions
        // with our own handlers.
        if !isInstalled {
            let handler: @convention(c) (Int32) -> Void = { sig in SignalCrashHandler.handle(sig) }
            for (i, sig) in monitoredSignals.enumerated() {
                var newAction = Darwin.sigaction()
                newAction.__sigaction_u.__sa_handler = handler
                newAction.sa_flags = 0
                sigemptyset(&newAction.sa_mask)
                _ = sigaction(sig, &newAction, &previousActions[i])
            }
            isInstalled = true
        }
    }

    static func uninstall() {
        if isInstalled {
            // Restore each signal to whatever handler was in place before install().
            var ignored = Darwin.sigaction()
            for (i, sig) in monitoredSignals.enumerated() {
                var prev = previousActions[i]
                _ = sigaction(sig, &prev, &ignored)
            }
            isInstalled = false
        }
        if pendingFd >= 0 { Darwin.close(pendingFd); pendingFd = -1 }
        if !pendingPath.isEmpty {
            try? FileManager.default.removeItem(atPath: pendingPath)
            pendingPath = ""
        }
    }

    // MARK: - Signal handler (async-signal-safe context only)

    private static func handle(_ sig: Int32) {
        // Reset to SIG_DFL immediately so a second fault terminates cleanly
        // rather than re-entering this handler.
        var resetAction = Darwin.sigaction()
        resetAction.__sigaction_u.__sa_handler = SIG_DFL
        resetAction.sa_flags = 0
        sigemptyset(&resetAction.sa_mask)
        var ignored = Darwin.sigaction()
        _ = sigaction(sig, &resetAction, &ignored)

        if sig == SIGABRT && exceptionAlreadyCaptured { chainPrevious(sig); return }

        let fd = pendingFd
        guard fd >= 0 else { chainPrevious(sig); return }

        let frameCount = frameBuffer.withUnsafeMutableBufferPointer { ptr in
            backtrace(ptr.baseAddress, Int32(ptr.count))
        }

        var tv = timeval()
        gettimeofday(&tv, nil)

        _ = Darwin.lseek(fd, 0, SEEK_SET)

        writeCrashFile(fd: fd, sig: sig,
                       tsMs:      Int64(tv.tv_sec) * 1000,
                       frameCount: Int(frameCount))

        chainPrevious(sig)
    }

    // Signal-safe: reads pre-allocated arrays only; sigaction() is async-signal-safe (POSIX).
    // Restores the previously installed handler for this signal (if it is a real function,
    // not SIG_DFL/SIG_IGN) so that Crashlytics, Sentry, etc. also process the crash.
    private static func chainPrevious(_ sig: Int32) {
        var idx = -1
        let count = monitoredSignals.count
        for i in 0..<count {
            if monitoredSignals[i] == sig { idx = i; break }
        }
        guard idx >= 0 else { raise(sig); return }

        let prev = previousActions[idx]
        // SIG_DFL is nil (address 0), SIG_IGN is address 1 — both mean "no real handler".
        // Call the previous handler function directly (signal-safe: no sigaction() call needed).
        // The previous handler (Crashlytics/Sentry) will terminate or re-raise the signal;
        // our own handler is already reset to SIG_DFL above, so the fall-through raise() is
        // the safety net only if the previous handler somehow returns.
        if let h = prev.__sigaction_u.__sa_handler, unsafeBitCast(h, to: UInt.self) > 1 {
            h(sig)
        }
        raise(sig)
    }

    // MARK: - Binary crash writer (signal-safe — no allocations)

    // File format v2 (magic 0x4D534948 "MSIH") — per-frame image slides:
    //   magic         UInt32
    //   signal        Int32
    //   timestampMs   Int64
    //   sessionLen    UInt16   (includes null terminator)
    //   sessionId     [CChar]
    //   frameCount    UInt16
    //   frames        [{addrRelative: UInt64, preferredBase: UInt64}] × frameCount
    //
    // addrRelative  = PC − image_base_at_crash  (offset within the binary, stable across relaunches)
    // preferredBase = image_base_at_crash − aslr_slide  (cross-launch image identifier)
    // preferredBase == 0 means the image could not be identified; reader outputs raw hex.

    // Signal-safe: iterates pre-allocated arrays only; no system calls, no allocation.
    private static func findImageIndex(for pc: UInt64) -> Int? {
        var bestIdx:  Int?   = nil
        var bestBase: UInt64 = 0
        let count = Int(imageCapturedCount)
        for i in 0..<count {
            let base = imageBaseAddrs[i]
            if base > 0 && base <= pc && base > bestBase {
                bestBase = base
                bestIdx  = i
            }
        }
        return bestIdx
    }

    private static func writeCrashFile(fd: Int32, sig: Int32, tsMs: Int64, frameCount: Int) {
        var magic: UInt32 = 0x4D534948
        withUnsafeBytes(of: &magic)      { _ = Darwin.write(fd, $0.baseAddress, $0.count) }
        var sigVal = sig
        withUnsafeBytes(of: &sigVal)     { _ = Darwin.write(fd, $0.baseAddress, $0.count) }
        var ts = tsMs
        withUnsafeBytes(of: &ts)         { _ = Darwin.write(fd, $0.baseAddress, $0.count) }
        var sessionLen = UInt16(sessionIdCStr.count)
        withUnsafeBytes(of: &sessionLen) { _ = Darwin.write(fd, $0.baseAddress, $0.count) }
        sessionIdCStr.withUnsafeBufferPointer { _ = Darwin.write(fd, $0.baseAddress, $0.count) }
        var fc = UInt16(frameCount)
        withUnsafeBytes(of: &fc)         { _ = Darwin.write(fd, $0.baseAddress, $0.count) }

        frameBuffer.withUnsafeBufferPointer { buf in
            for i in 0..<min(frameCount, 32) {
                let addr = UInt64(UInt(bitPattern: buf[i]))
                var addrRel:      UInt64
                var preferredBase: UInt64
                if let idx = findImageIndex(for: addr) {
                    let base  = imageBaseAddrs[idx]
                    let slide = imageAslrSlides[idx]
                    addrRel       = addr &- base
                    preferredBase = base &- UInt64(bitPattern: slide)
                } else {
                    addrRel       = addr   // raw; reader will output hex
                    preferredBase = 0      // sentinel: image unknown
                }
                withUnsafeBytes(of: &addrRel)       { _ = Darwin.write(fd, $0.baseAddress, $0.count) }
                withUnsafeBytes(of: &preferredBase)  { _ = Darwin.write(fd, $0.baseAddress, $0.count) }
            }
        }
    }
}