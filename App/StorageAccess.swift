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
    /// `.checking`: access is there, the helper is being put in place.
    enum Phase { case ready, checking, getting, failed }

    static let folder = "/private/var/ResizeAPFS"
    static let helper = folder + "/resize-helper"
    static let daemon = "/var/jb/Library/LaunchDaemons/dev.omarchy.resize-apfs.plist"
    static let ipc = "/var/run/resize-apfs"
    /// scripts/build-device.sh puts this in front of the helper in the app bundle, so that
    /// signing the app with an Apple ID leaves the helper's own signature alone.
    static let payloadPrefix = Data("RESIZE-APFS-HELPER\n".utf8)

    private let bridge: AccessBridge
    private let queue = DispatchQueue(label: "resize.access", qos: .userInitiated)
    /// The app's own folder for the two files below. Found once, at launch: obtaining access
    /// moves the process's home folder to root's, so nothing may ask for it later (and
    /// UserDefaults stops reaching the app's settings).
    private let folder: URL
    /// The last attempt, kept across launches: "started" while one runs (it stays if the
    /// device restarted during it), "failed", or "restarted" after the screen restart some
    /// older devices need first. No file when access was obtained or never tried.
    private var attemptFile: URL { folder.appendingPathComponent("attempt") }
    /// What happened, step by step, for whoever looks into a failure. The pages say little.
    private var logFile: URL { folder.appendingPathComponent("access.log") }

    init(bridge: AccessBridge) {
        self.bridge = bridge
        folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/ResizeAPFS")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Made here, as the app's user: later lines may come from root.
        if !FileManager.default.fileExists(atPath: logFile.path) { FileManager.default.createFile(atPath: logFile.path, contents: nil) }
        log("launch, pid \(getpid())")
    }

    func log(_ text: String) {
        NSLog("Resize APFS: %@", text)
        guard let handle = try? FileHandle(forWritingTo: logFile) else { return }
        defer { handle.closeFile() }
        // The last launches are enough.
        if handle.seekToEndOfFile() > 200_000 { handle.truncateFile(atOffset: 0) }
        handle.write(Data("\(Self.stamp.string(from: Date())) \(text)\n".utf8))
    }
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    /// As root and outside the sandbox, one block at a time: root is a state of the whole
    /// process, and a second thread entering or leaving it would end it under the first.
    /// Only files are read and written and the helper's socket is opened in such a block. The
    /// app never starts a program from one: on iOS 18 that restarted the device.
    func privileged(_ block: () -> Void) {
        elevation.lock()
        defer { elevation.unlock() }
        bridge.privileged(block)
    }
    private let elevation = NSLock()

    /// Obtains access unless it is there. `update` runs on the main queue: at once with
    /// `.getting` or `.failed`, later with `.failed` or `.ready`. A successful attempt ends
    /// with the screen restarting, and with it the app; the helper opens the app again.
    /// After an attempt that did not finish, nothing is tried until `retry`.
    func begin(retry: Bool, update: @escaping (Phase) -> Void) {
        let last = (try? String(contentsOf: attemptFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        log("begin: ready \(bridge.isReady()), last attempt \(last ?? "none"), retry \(retry)")
        if bridge.isReady() {
            update(.checking)
            queue.async { [self] in
                installHelper(elevated: false)
                describeHelper()
                // The helper starts with the screen restart that follows obtaining access. Where
                // it is not there (access from before this app had its helper in place), the
                // screen restarts once more; a second time would not help either.
                if helperServing(within: 45) || last == "restarting" {
                    record(nil)
                    return DispatchQueue.main.async { update(.ready) }
                }
                log("no helper is serving: restarting the screen to start it")
                record("restarting")
                DispatchQueue.main.async { update(.getting) }
                bridge.finish()
            }
            return
        }
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
            var prepared = false
            if let error = bridge.obtain({ [self] in prepared = true; installHelper(elevated: true) }) { return fail(error, update) }
            record(nil)
            log("access obtained, helper prepared \(prepared); restarting the screen")
            bridge.finish()
        }
    }

    private func fail(_ reason: String, _ update: @escaping (Phase) -> Void) {
        log("storage access failed: \(reason)")
        record("failed")
        DispatchQueue.main.async { update(.failed) }
    }

    private func record(_ attempt: String?) {
        guard let attempt else { try? FileManager.default.removeItem(at: attemptFile); return }
        // Replaced as a whole, so it does not matter which user wrote the last one.
        try? Data(attempt.utf8).write(to: attemptFile, options: .atomic)
    }

    /// Run on the app's own queue, where the attempt is.
    func note(_ text: String) { queue.async { [self] in log(text) } }

    /// What is there of the helper, for the log.
    private func describeHelper() {
        var facts = "the privileged block did not run"
        var helperLog: String?
        privileged {
            let files = FileManager.default
            func size(_ path: String) -> String { (try? files.attributesOfItem(atPath: path)[.size]).map { "\($0) bytes" } ?? "missing" }
            let served = (try? files.contentsOfDirectory(atPath: Self.ipc))?.sorted().joined(separator: " ") ?? "missing"
            facts = "uid \(geteuid()); helper \(size(Self.helper)); daemon \(size(Self.daemon)); \(Self.ipc): \(served)"
            helperLog = files.contents(atPath: Self.folder + "/helper.log").flatMap { String(data: $0.suffix(1500), encoding: .utf8) }
        }
        log(facts)
        log(helperLog.map { "helper.log ends: \($0)" } ?? "no helper.log")
    }

    /// True once the helper has published its connection credentials, checked every two seconds.
    private func helperServing(within seconds: Int) -> Bool {
        for attempt in 0...(seconds / 2) {
            var serving = false
            privileged { serving = FileManager.default.fileExists(atPath: Self.ipc + "/client.token") }
            if serving { log("the helper is serving"); return true }
            if attempt < seconds / 2 { Thread.sleep(forTimeInterval: 2) }
        }
        return false
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

    /// Puts this app's helper and its launch daemon in place unless they are there already.
    /// `elevated`: called inside the privileged block that follows obtaining access. Nothing
    /// is started here: the daemon starts with the next screen restart, and a running helper
    /// keeps its own file until then (the new one replaces it by name).
    private func installHelper(elevated: Bool) {
        guard let payload = bundledHelper(), let identifier = Bundle.main.bundleIdentifier,
              let process = Bundle.main.executableURL?.lastPathComponent,
              let plist = daemonPlist(identifier: identifier, process: process) else {
            return log("this copy of the app has no storage helper")
        }
        var outcome = "the privileged block did not run"
        let install = { [self] in
            let files = FileManager.default
            if files.contents(atPath: Self.helper) == payload && files.contents(atPath: Self.daemon) == plist {
                outcome = "helper and daemon are in place"
                return
            }
            try? files.createDirectory(atPath: Self.folder, withIntermediateDirectories: true)
            try? files.createDirectory(atPath: (Self.daemon as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let done = chown(Self.folder, 0, 0) == 0 && chmod(Self.folder, 0o755) == 0
                && write(payload, to: Self.helper, mode: 0o755) && write(plist, to: Self.daemon, mode: 0o644)
            outcome = done ? "helper and daemon installed" : "could not install the storage helper, uid \(geteuid()): \(String(cString: strerror(errno)))"
        }
        if elevated { install() } else { privileged(install) }
        log(outcome)
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
        // Dopamine's app delegate answers for scenes, so iOS gives the app one even without a
        // scene configuration in Info.plist, and shows only windows that belong to it.
        if #available(iOS 13, *) {
            func attach(_ scene: UIScene?) {
                guard let scene = scene as? UIWindowScene, window.windowScene == nil else { return }
                window.windowScene = scene
                window.frame = scene.coordinateSpace.bounds
                window.makeKeyAndVisible()
            }
            attach(UIApplication.shared.connectedScenes.first { $0 is UIWindowScene })
            center.addObserver(forName: UIScene.willConnectNotification, object: nil, queue: .main) { attach($0.object as? UIScene) }
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in model.connect() }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in model.disconnectUI() }
        model.connect()
    }
}
