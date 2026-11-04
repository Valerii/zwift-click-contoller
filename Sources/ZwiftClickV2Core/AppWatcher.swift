import AppKit

/// Watches for a target app (by name or bundle ID) launching and quitting.
/// Calls `onLaunch` / `onQuit` on the main thread.
public final class AppWatcher {
    private let target: String // lowercased app name or bundle ID
    private var observers: [NSObjectProtocol] = []
    public var onLaunch: (() -> Void)?
    public var onQuit:   (() -> Void)?

    public init(appNameOrBundleID: String) {
        self.target = appNameOrBundleID.lowercased()
    }

    public func start() {
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                        object: nil, queue: .main) { [weak self] note in
            self?.handle(note, event: .launch)
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                        object: nil, queue: .main) { [weak self] note in
            self?.handle(note, event: .quit)
        })

        if isTargetRunning() {
            Log.info("[\(target)] already running - connecting.")
            onLaunch?()
        } else {
            Log.info("Waiting for \(target) to launch...")
        }
    }

    public func stop() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
    }

    private enum Event { case launch, quit }

    private func handle(_ note: Notification, event: Event) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              matches(app) else { return }
        switch event {
        case .launch:
            Log.info("[\(app.localizedName ?? target)] launched - connecting Zwift Click v2.")
            onLaunch?()
        case .quit:
            Log.info("[\(app.localizedName ?? target)] quit - disconnecting Zwift Click v2.")
            onQuit?()
        }
    }

    private func matches(_ app: NSRunningApplication) -> Bool {
        app.localizedName?.lowercased() == target || app.bundleIdentifier?.lowercased() == target
    }

    private func isTargetRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { matches($0) }
    }
}
