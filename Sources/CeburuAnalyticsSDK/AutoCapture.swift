import Foundation
#if canImport(UIKit)
import UIKit
import ObjectiveC

/// Automatic capture for UIKit apps, installed by `initialize` when `Config.autoCapture` is on: a
/// `screen_view` span per appearing view controller of the app's own bundle (containers and system
/// controllers such as SwiftUI's hosting controller are skipped), foreground/background transitions and
/// the cold start (process start → first screen). SwiftUI screens are reported with `trackScreen(_:)`.
///
/// A `screen_view` span runs from `viewWillAppear` to `viewDidAppear`, so its duration is the time the screen took
/// to show. `app_start` is reported as `cold` (process start → first screen), `warm` (a prewarmed launch: SDK
/// start → first screen, since the process start is not the user's tap) and `hot` (return from the background:
/// `willEnterForeground` → `didBecomeActive`).
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
    private static var pendingColdStart: (start: Date, end: Date, type: String)?
    private static var pendingScreens: [(name: String, start: Date, end: Date)] = []
    /// When AutoCapture was first touched: the start of a prewarmed (warm) launch.
    private static var firstSeen: Date?
    /// Set by `willEnterForeground`, cleared when the hot start is recorded.
    private static var hotStartBegan: Date?
    private static var willAppearKey: UInt8 = 0
    private static let maxPendingScreens = 20

    /// Starts watching screens before the SDK is running. Safe to call more than once.
    static func prepare() {
        if firstSeen == nil { firstSeen = Date() }
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
        if firstSeen == nil { firstSeen = Date() }
        swizzle()
        everInstalled = true
        buffering = false
        recordPending()
        guard observers.isEmpty else { return }
        // A launch into the background (background fetch, audio, push) starts in the background state.
        if UIApplication.shared.applicationState == .background {
            Task { await CeburuAnalyticsSDK.shared.recordAppState(foreground: false) }
        }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { hotStartBegan = Date() }
                Task { await CeburuAnalyticsSDK.shared.recordAppState(foreground: true) }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                // didBecomeActive also follows a dismissed alert or Control Center; only a return from the background counts.
                MainActor.assumeIsolated {
                    guard let began = hotStartBegan else { return }
                    hotStartBegan = nil
                    let end = Date()
                    // A start that took over a minute was not a user waiting (e.g. paused in a debugger).
                    guard end.timeIntervalSince(began) < 60 else { return }
                    Task { await CeburuAnalyticsSDK.shared.recordAppStart(began, end: end, type: "hot") }
                }
            },
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                Task { await CeburuAnalyticsSDK.shared.recordAppState(foreground: false) }
            }
        ]
    }

    private static func swizzle() {
        guard !installed else { return }
        installed = true
        exchange(#selector(UIViewController.viewWillAppear(_:)), #selector(UIViewController.ceburu_viewWillAppear(_:)))
        exchange(#selector(UIViewController.viewDidAppear(_:)), #selector(UIViewController.ceburu_viewDidAppear(_:)))
    }

    private static func exchange(_ original: Selector, _ replacement: Selector) {
        if let a = class_getInstanceMethod(UIViewController.self, original),
           let b = class_getInstanceMethod(UIViewController.self, replacement) {
            method_exchangeImplementations(a, b)
        }
    }

    private static func isTracked(_ controller: UIViewController) -> Bool {
        if controller is UINavigationController || controller is UITabBarController ||
           controller is UISplitViewController || controller is UIPageViewController { return false }
        return Bundle(for: type(of: controller)) == Bundle.main
    }

    static func willAppear(_ controller: UIViewController) {
        guard isTracked(controller) else { return }
        objc_setAssociatedObject(controller, &willAppearKey, Date(), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private static func recordPending() {
        let coldStart = pendingColdStart
        let screens = pendingScreens
        pendingColdStart = nil
        pendingScreens.removeAll()
        guard coldStart != nil || !screens.isEmpty else { return }
        Task {
            if let coldStart { await CeburuAnalyticsSDK.shared.recordAppStart(coldStart.start, end: coldStart.end, type: coldStart.type) }
            for screen in screens { await CeburuAnalyticsSDK.shared.recordScreen(screen.name, start: screen.start, end: screen.end) }
        }
    }

    /// Notification observers are removed; the swizzled method stays in place but records nothing while the SDK is stopped.
    static func uninstall() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    static func didAppear(_ controller: UIViewController) {
        guard isTracked(controller) else { return }
        let end = Date()
        let began = objc_getAssociatedObject(controller, &willAppearKey) as? Date
        objc_setAssociatedObject(controller, &willAppearKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        // No willAppear seen (e.g. swizzled mid-transition) or a stale one: fall back to a zero-length span.
        let start = began.map { end.timeIntervalSince($0) < 60 ? $0 : end } ?? end
        let name = [controller.title, controller.navigationItem.title].compactMap { $0 }.first { !$0.isEmpty }
            ?? String(describing: type(of: controller))
        var launch: (start: Date, type: String)?
        if !coldStartReported {
            coldStartReported = true
            launch = launchStart()
        }
        if buffering {
            if let launch { pendingColdStart = (launch.start, end, launch.type) }
            if pendingScreens.count < maxPendingScreens { pendingScreens.append((name, start, end)) }
            return
        }
        Task {
            if let launch { await CeburuAnalyticsSDK.shared.recordAppStart(launch.start, end: end, type: launch.type) }
            await CeburuAnalyticsSDK.shared.recordScreen(name, start: start, end: end)
        }
    }

    /// The first screen's launch: `cold` from process start, or `warm` from SDK start for a prewarmed process.
    private static func launchStart() -> (start: Date, type: String)? {
        if ProcessInfo.processInfo.environment["ActivePrewarm"] == "1" {
            guard let firstSeen, Date().timeIntervalSince(firstSeen) <= 30 else { return nil }
            return (firstSeen, "warm")
        }
        return processStart().map { ($0, "cold") }
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
    // After method_exchangeImplementations this name points at UIKit's viewWillAppear.
    @objc func ceburu_viewWillAppear(_ animated: Bool) {
        ceburu_viewWillAppear(animated)
        AutoCapture.willAppear(self)
    }

    // After method_exchangeImplementations this name points at UIKit's viewDidAppear.
    @objc func ceburu_viewDidAppear(_ animated: Bool) {
        ceburu_viewDidAppear(animated)
        AutoCapture.didAppear(self)
    }
}
#endif
