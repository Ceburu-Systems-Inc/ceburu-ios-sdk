import Foundation
#if canImport(UIKit)
import UIKit
import ObjectiveC

/// Automatic capture for UIKit apps, installed by `initialize` when `Config.autoCapture` is on: a
/// `screen_view` span per appearing view controller of the app's own bundle (containers and system
/// controllers such as SwiftUI's hosting controller are skipped), foreground/background transitions and
/// the cold start (process start → first screen). SwiftUI screens are reported with `trackScreen(_:)`.
///
/// `initialize` is slow enough that the first screen can appear before it finishes, so screens are watched from
/// ``prepare()`` and what appears before ``install()`` is held and recorded once the SDK is running. Recording
/// goes through the SDK's own running and consent checks, so nothing is kept without consent.
@MainActor
enum AutoCapture {
    private static var installed = false
    private static var observers: [NSObjectProtocol] = []
    private static var coldStartReported = false
    private static var buffering = false
    private static var everInstalled = false
    private static var pendingColdStart: (start: Date, end: Date)?
    private static var pendingScreens: [(name: String, at: Date)] = []
    private static let maxPendingScreens = 20

    /// Starts watching screens before the SDK is running. Safe to call more than once.
    static func prepare() {
        swizzle()
        if !everInstalled { buffering = true }
    }

    /// Drops anything held by ``prepare()``: `autoCapture` is off.
    static func discardPending() {
        buffering = false
        pendingColdStart = nil
        pendingScreens.removeAll()
    }

    static func install() {
        swizzle()
        everInstalled = true
        buffering = false
        recordPending()
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
                Task { await CeburuAnalyticsSDK.shared.recordAppState(foreground: true) }
            },
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                Task { await CeburuAnalyticsSDK.shared.recordAppState(foreground: false) }
            }
        ]
    }

    private static func swizzle() {
        if !installed, let original = class_getInstanceMethod(UIViewController.self, #selector(UIViewController.viewDidAppear(_:))),
           let swizzled = class_getInstanceMethod(UIViewController.self, #selector(UIViewController.ceburu_viewDidAppear(_:))) {
            method_exchangeImplementations(original, swizzled)
            installed = true
        }
    }

    private static func recordPending() {
        let coldStart = pendingColdStart
        let screens = pendingScreens
        pendingColdStart = nil
        pendingScreens.removeAll()
        guard coldStart != nil || !screens.isEmpty else { return }
        Task {
            if let coldStart { await CeburuAnalyticsSDK.shared.recordColdStart(coldStart.start, end: coldStart.end) }
            for screen in screens { await CeburuAnalyticsSDK.shared.recordScreen(screen.name, start: screen.at, end: screen.at) }
        }
    }

    /// Notification observers are removed; the swizzled method stays in place but records nothing while the SDK is stopped.
    static func uninstall() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    static func didAppear(_ controller: UIViewController) {
        if controller is UINavigationController || controller is UITabBarController ||
           controller is UISplitViewController || controller is UIPageViewController { return }
        guard Bundle(for: type(of: controller)) == Bundle.main else { return }
        let name = controller.title?.isEmpty == false ? controller.title! : String(describing: type(of: controller))
        let coldStart = coldStartReported ? nil : processStart()
        coldStartReported = true
        if buffering {
            if let coldStart { pendingColdStart = (coldStart, Date()) }
            if pendingScreens.count < maxPendingScreens { pendingScreens.append((name, Date())) }
            return
        }
        Task {
            if let coldStart { await CeburuAnalyticsSDK.shared.recordColdStart(coldStart) }
            await CeburuAnalyticsSDK.shared.recordScreen(name, start: Date())
        }
    }

    /// Process start time, or nil when it is not a plausible user launch (prewarmed, or more than 30 s ago).
    static func processStart() -> Date? {
        if ProcessInfo.processInfo.environment["ActivePrewarm"] == "1" { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let time = info.kp_proc.p_un.__p_starttime
        let start = Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000)
        return Date().timeIntervalSince(start) <= 30 ? start : nil
    }
}

extension CeburuAnalyticsSDK {
    /// Starts watching for the first screen at once, so a slow ``initialize(config:)`` cannot miss the cold start.
    ///
    /// Optional, for apps that start the SDK from a `Task`: call it first, on the main thread, in
    /// `application(_:didFinishLaunchingWithOptions:)`. What it sees is held in memory and recorded once the SDK
    /// is running with consent, and dropped otherwise.
    @MainActor public static func prepareAutoCapture() {
        AutoCapture.prepare()
    }
}

extension UIViewController {
    // After method_exchangeImplementations this name points at UIKit's viewDidAppear.
    @objc func ceburu_viewDidAppear(_ animated: Bool) {
        ceburu_viewDidAppear(animated)
        AutoCapture.didAppear(self)
    }
}
#endif
