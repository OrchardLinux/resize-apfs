import UIKit
import ResizeCore

/// What Access/AccessBridge.m offers (its RAFAccessBridge), as Swift calls it.
@objc protocol AccessBridge {
    func isReady() -> Bool
    func needsScreenRestart() -> Bool
    func restartScreen()
    func obtain(_ prepare: @escaping () -> Void) -> String?
    func finish()
    func privileged(_ block: () -> Void)
}

/// Storage access for the app installed without DFU: the app obtains it by itself when it
/// opens, installs the storage helper as a launch daemon and reaches it as root. With DFU
/// the boot provides all of this and the app has no StorageAccess.
final class StorageAccess: @unchecked Sendable {
    enum Phase { case ready, getting, failed }

    static let folder = "/private/var/ResizeAPFS"
    static let helper = folder + "/resize-helper"
    static let daemon = "/var/jb/Library/LaunchDaemons/dev.omarchy.resize-apfs.plist"
    static let launchctl = "/var/jb/usr/bin/launchctl"
    /// scripts/build-device.sh puts this in front of the helper in the app bundle, so that
    /// signing the app with an Apple ID leaves the helper's own signature alone.
    static let payloadPrefix = Data("RESIZE-APFS-HELPER\n".utf8)

    /// The last attempt, kept across launches: "started" while one runs (it stays if the
    /// device restarted during it), "failed", or "restarted" after the screen restart some
    /// older devices need first. Absent when access was obtained or never tried.
    private static let attemptKey = "storageAccessAttempt"
    private let bridge: AccessBridge
    private let queue = DispatchQueue(label: "resize.access", qos: .userInitiated)
    private let defaults = UserDefaults.standard

    init(bridge: AccessBridge) { self.bridge = bridge }

    func privileged(_ block: () -> Void) { bridge.privileged(block) }

    /// Obtains access unless it is there. `update` runs on the main queue: at once with
    /// `.getting` or `.failed`, later with `.failed` or `.ready`. A successful attempt ends
    /// with the screen restarting, and with it the app; the helper opens the app again.
    /// After an attempt that did not finish, nothing is tried until `retry`.
    func begin(retry: Bool, update: @escaping (Phase) -> Void) {
        if bridge.isReady() {
            queue.async { [self] in
                bridge.privileged { installHelper(restart: true) }
                DispatchQueue.main.async { update(.ready) }
            }
            return
        }
        let last = defaults.string(forKey: Self.attemptKey)
        if !retry, last == "started" || last == "failed" { update(.failed); return }
        record("started")
        update(.getting)
        queue.async { [self] in
            if bridge.needsScreenRestart() {
                // Once: a device that still needs it after the restart cannot be helped by another.
                guard last != "restarted" else { return fail("The screen restart did not help.", update) }
                record("restarted")
                bridge.restartScreen()
                return
            }
            if let error = bridge.obtain({ [self] in installHelper(restart: false) }) { return fail(error, update) }
            record(nil)
            bridge.finish()
        }
    }

    private func fail(_ reason: String, _ update: @escaping (Phase) -> Void) {
        NSLog("Resize APFS: storage access failed: %@", reason)
        record("failed")
        DispatchQueue.main.async { update(.failed) }
    }

    private func record(_ attempt: String?) {
        defaults.set(attempt, forKey: Self.attemptKey)
        defaults.synchronize()
    }

    // MARK: Helper

    private func bundledHelper() -> Data? {
        guard let url = Bundle.main.url(forResource: "resize-helper", withExtension: "payload"),
              let data = try? Data(contentsOf: url), data.starts(with: Self.payloadPrefix) else { return nil }
        return Data(data.dropFirst(Self.payloadPrefix.count))
    }

    /// The launch daemon: the helper serving this app, started with every screen restart
    /// that follows obtaining access. It opens the app once the device is unlocked.
    private func daemonPlist(identifier: String, process: String) -> Data? {
        let plist: [String: Any] = [
            "Label": "dev.omarchy.resize-apfs",
            "ProgramArguments": [Self.helper, "--allow-writes", "--embedded", identifier, process],
            "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 30,
            "UserName": "root", "GroupName": "wheel",
            "ProcessType": "Interactive", "AbandonProcessGroup": true,
            "StandardOutPath": Self.folder + "/helper.log", "StandardErrorPath": Self.folder + "/helper.log",
            "JetsamProperties": ["JetsamPriority": 160, "JetsamMemoryLimit": 256],
        ]
        return try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    /// As root, outside the sandbox: puts this app's helper and its launch daemon in place
    /// unless they are there already. `restart`: access is there, so the daemon is started
    /// (again) now; otherwise the screen restart that follows starts it. A helper that is
    /// resizing is left alone: the next launch replaces it.
    private func installHelper(restart: Bool) {
        guard let payload = bundledHelper(), let identifier = Bundle.main.bundleIdentifier,
              let process = Bundle.main.executableURL?.lastPathComponent,
              let plist = daemonPlist(identifier: identifier, process: process) else {
            NSLog("Resize APFS: this copy of the app has no storage helper")
            return
        }
        let files = FileManager.default
        let installed = files.contents(atPath: Self.helper)
        if installed == payload && files.contents(atPath: Self.daemon) == plist { return }
        if restart, installed != nil, run([Self.helper, "--operation-active"]) == 0 { return }
        try? files.createDirectory(atPath: Self.folder, withIntermediateDirectories: true)
        try? files.createDirectory(atPath: (Self.daemon as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard chown(Self.folder, 0, 0) == 0, chmod(Self.folder, 0o755) == 0,
              write(payload, to: Self.helper, mode: 0o755), write(plist, to: Self.daemon, mode: 0o644) else {
            NSLog("Resize APFS: could not install the storage helper: %s", strerror(errno))
            return
        }
        if restart {
            _ = run([Self.launchctl, "unload", Self.daemon])
            NSLog("Resize APFS: storage helper started, launchctl exit %d", run([Self.launchctl, "load", Self.daemon]))
        }
    }

    /// Replaces `path` in one step, owned by root, so a running helper keeps its own file.
    private func write(_ data: Data, to path: String, mode: mode_t) -> Bool {
        let pending = path + ".new"
        unlink(pending)
        guard FileManager.default.createFile(atPath: pending, contents: data),
              chown(pending, 0, 0) == 0, chmod(pending, mode) == 0, rename(pending, path) == 0 else {
            unlink(pending)
            return false
        }
        return true
    }

    private func run(_ argv: [String]) -> Int32 {
        var pid: pid_t = 0
        let args = argv.map { strdup($0) } + [nil]
        defer { args.forEach { free($0) } }
        guard posix_spawn(&pid, argv[0], nil, nil, args, environ) == 0 else { return -1 }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 { if errno != EINTR { return -1 } }
        return status & 0x7f == 0 ? (status >> 8) & 0xff : -1
    }
}

/// The app's start inside the Dopamine app: what AppDelegate does for the app booted with
/// DFU, begun by Access/AccessBridge.m once the host app has launched.
@objc(RAFEmbeddedApp) final class EmbeddedApp: NSObject {
    private static var window: UIWindow?
    private static var model: AppModel?

    @objc(startWithBridge:) static func start(bridge: AnyObject) {
        guard window == nil else { return }
        let model = AppModel(access: StorageAccess(bridge: unsafeBitCast(bridge, to: AccessBridge.self)))
        let window = UIWindow(frame: UIScreen.main.bounds)
        if #available(iOS 13, *) { window.overrideUserInterfaceStyle = .dark }
        window.backgroundColor = Theme.background
        window.tintColor = Theme.blue
        window.rootViewController = RootViewController(model: model)
        window.makeKeyAndVisible()
        self.window = window
        self.model = model
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in model.connect() }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in model.disconnectUI() }
        model.connect()
    }
}
