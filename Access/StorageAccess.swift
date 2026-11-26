// Shared by every app that is installed without DFU inside the Dopamine app: Resize APFS
// here, the Orchard installer in the tools repository (which compiles this file and
// AccessBridge.m from a checkout of this one). Each app brings a Configuration and its own
// pages and start (`RAFEmbeddedApp`, App/EmbeddedApp.swift here).
import UIKit

/// What Access/AccessBridge.m offers (its RAFAccessBridge), as Swift calls it.
@objc protocol AccessBridge {
    func isReady() -> Bool
    func needsScreenRestart() -> Bool
    func restartScreen()
    func obtain(_ prepare: @escaping () -> Void) -> String?
    func finish()
    func privileged(_ block: () -> Void)
}

/// Storage access for an app installed without DFU: the app obtains it once the user has
/// agreed, installs its helper as a launch daemon and reaches it as root. With DFU the boot
/// provides all of this and the app has no StorageAccess.
final class StorageAccess: @unchecked Sendable {
    /// What differs between the apps.
    struct Configuration {
        /// The app's name, for the log.
        var name: String
        /// The app's own folder for its note and log, in its Library/Application Support.
        var state: String
        /// The helper's folder on the data partition: its log and, in `run`, its socket.
        var folder: String
        /// The launch daemon's label; its file is this name in Dopamine's LaunchDaemons.
        var label: String
        /// What the app brings in its bundle (`resource`.payload) and where each goes. The
        /// first is the helper. Inside the jailbreak root: iOS 15 and later lets launchd start
        /// programs only from there, not from the data partition.
        var payloads: [(resource: String, path: String)]
        /// The helper's own arguments; where it serves and whom follow them.
        var arguments: [String]
        /// A file the helper holds locked while it runs, to say in the log whether it does.
        var lock: String
        /// What to remove when the helper is put in place: files of earlier ways to start it,
        /// and the launch daemon of another app that shares this one's place on the device.
        var leftovers: [String]

        var helper: String { payloads[0].path }
        var daemon: String { "/var/jb/Library/LaunchDaemons/\(label).plist" }
        /// Where the helper publishes its socket and credentials. Not /var/run: the helper
        /// starts early in the screen restart, and iOS empties /var/run after that, leaving
        /// the helper listening on a socket nobody can find.
        var ipc: String { folder + "/run" }
    }
    let configuration: Configuration
    /// `.start`: nothing has happened yet, the user is told what will. `.getting`: access is
    /// being obtained. `.checking`: access is there, the helper is being put in place.
    enum Phase { case ready, checking, start, getting, failed }
    /// Why `begin` runs: the app opened, or the user pressed Continue or Try again.
    enum Entry { case launch, confirmed, retry }
    /// How long the note about the first screen restart counts. Opened later than this, the
    /// app starts from its first page again instead of restarting the screen unasked.
    static let resumeWindow: TimeInterval = 120

    /// The build puts this in front of every payload in the app bundle, so that signing the
    /// app with an Apple ID leaves the payload's own signature alone (a signer re-signs every
    /// program it finds).
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

    init(bridge: AccessBridge, configuration: Configuration) {
        self.bridge = bridge
        self.configuration = configuration
        folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/" + configuration.state)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Made here, as the app's user: later lines may come from root.
        if !FileManager.default.fileExists(atPath: logFile.path) { FileManager.default.createFile(atPath: logFile.path, contents: nil) }
        log("launch, pid \(getpid())")
    }

    func log(_ text: String) {
        NSLog("%@: %@", configuration.name, text)
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

    /// Shows where things stand and, once the user has agreed, obtains access. `update` runs
    /// on the main queue, at once and again when the phase changes. Nothing is triggered
    /// before Continue (`.start`), except to go on after the first screen restart that some
    /// devices need: the app left a note before it. A successful attempt ends with the screen
    /// restarting, and with it the app; the helper opens the app again. After an attempt that
    /// did not finish, nothing is tried until Try again.
    func begin(_ entry: Entry, update: @escaping (Phase) -> Void) {
        let note = ((try? String(contentsOf: attemptFile, encoding: .utf8)) ?? "").split(separator: " ").map(String.init)
        var last = note.first
        let restartedAt = note.count > 1 ? TimeInterval(note[1]) : nil
        if last == "restarted", Date().timeIntervalSince1970 - (restartedAt ?? 0) > Self.resumeWindow { last = nil }
        log("begin: ready \(bridge.isReady()), last attempt \(last ?? "none"), entry \(entry)")
        if bridge.isReady() {
            update(.checking)
            queue.async { [self] in
                let changed = installHelper(elevated: false)
                describeHelper()
                // The helper starts with the screen restart that follows obtaining access. Where
                // it is not there (access from before this app had its helper in place), the
                // screen restarts once more; a second time would not help either.
                if helperServing(within: 45) || (last == "restarting" && !changed) {
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
        let resuming = entry == .launch && last == "restarted"
        if entry == .launch, !resuming {
            return update(last == "started" || last == "failed" ? .failed : .start)
        }
        record("started")
        update(.getting)
        queue.async { [self] in
            if bridge.needsScreenRestart() {
                // Still needed after the restart: the app was opened again too late, or the
                // restart did not help. The page says so; Try again restarts the screen again.
                guard !resuming else { return fail("The screen restart was not used in time.", update) }
                record("restarted \(Int(Date().timeIntervalSince1970))")
                log("this device needs its screen restarted first")
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
            func listing(_ path: String) -> String {
                do {
                    return try files.contentsOfDirectory(atPath: path).sorted().map { name -> String in
                        var info = stat()
                        guard lstat(path + "/" + name, &info) == 0 else { return name + "(?)" }
                        return "\(name)(\(String(info.st_mode & 0o7777, radix: 8)) \(info.st_uid):\(info.st_gid) \(info.st_size))"
                    }.joined(separator: " ")
                } catch { return "error \((error as NSError).code) \(String(cString: strerror(errno)))" }
            }
            // The helper holds this lock for as long as it runs.
            let lock = open(configuration.lock, O_RDWR)
            let running = lock < 0 ? "no lock file (\(String(cString: strerror(errno))))" : flock(lock, LOCK_EX | LOCK_NB) == 0 ? "not running" : "running"
            if lock >= 0 { flock(lock, LOCK_UN); close(lock) }
            let arguments = (files.contents(atPath: configuration.daemon).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) } as? [String: Any])?["ProgramArguments"] ?? "?"
            facts = "uid \(geteuid()); helper \(running), \(size(configuration.helper)); daemon \(arguments); \(configuration.folder): \(listing(configuration.folder)); \(configuration.ipc): \(listing(configuration.ipc))"
            helperLog = files.contents(atPath: configuration.folder + "/helper.log").flatMap { String(data: $0.suffix(600), encoding: .utf8) }
        }
        log(facts)
        log(helperLog.map { "helper.log ends: \($0)" } ?? "no helper.log")
    }

    /// True once the helper has published its connection credentials, checked every two seconds.
    private func helperServing(within seconds: Int) -> Bool {
        for attempt in 0...(seconds / 2) {
            var serving = false
            privileged { serving = FileManager.default.fileExists(atPath: configuration.ipc + "/client.token") }
            if serving { log("the helper is serving"); return true }
            if attempt < seconds / 2 { Thread.sleep(forTimeInterval: 2) }
        }
        return false
    }

    // MARK: Helper

    private func bundled(_ resource: String) -> Data? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "payload"),
              let data = try? Data(contentsOf: url), data.starts(with: Self.payloadPrefix) else { return nil }
        return Data(data.dropFirst(Self.payloadPrefix.count))
    }

    /// The launch daemon: the helper serving this app, started with every screen restart
    /// that follows obtaining access. It opens the app once the device is unlocked.
    private func daemonPlist(identifier: String, process: String) -> Data? {
        let plist: [String: Any] = [
            "Label": configuration.label,
            "ProgramArguments": [configuration.helper] + configuration.arguments + ["--ipc-dir", configuration.ipc, "--embedded", identifier, process],
            "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 30,
            "UserName": "root", "GroupName": "wheel",
            "ProcessType": "Interactive", "AbandonProcessGroup": true,
            "StandardOutPath": configuration.folder + "/helper.log", "StandardErrorPath": configuration.folder + "/helper.log",
            "JetsamProperties": ["JetsamPriority": 160, "JetsamMemoryLimit": 256],
        ]
        return try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    /// Puts this app's helper, what it runs and its launch daemon in place unless they are
    /// there already. `elevated`: called inside the privileged block that follows obtaining
    /// access. Nothing is started here: the daemon starts with the next screen restart, and a
    /// running helper keeps its own file until then (the new one replaces it by name).
    @discardableResult private func installHelper(elevated: Bool) -> Bool {
        var files: [(data: Data, path: String, mode: mode_t)] = []
        for payload in configuration.payloads {
            guard let data = bundled(payload.resource) else {
                log("this copy of the app lacks \(payload.resource)")
                return false
            }
            files.append((data, payload.path, 0o755))
        }
        guard let identifier = Bundle.main.bundleIdentifier, let process = Bundle.main.executableURL?.lastPathComponent,
              let plist = daemonPlist(identifier: identifier, process: process) else { return false }
        files.append((plist, configuration.daemon, 0o644))
        var outcome = "the privileged block did not run"
        let install = { [self] in
            let manager = FileManager.default
            if files.allSatisfy({ manager.contents(atPath: $0.path) == $0.data }) {
                outcome = "helper and daemon are in place"
                return
            }
            try? manager.createDirectory(atPath: configuration.folder, withIntermediateDirectories: true)
            for path in configuration.leftovers { try? manager.removeItem(atPath: path) }
            var done = chown(configuration.folder, 0, 0) == 0 && chmod(configuration.folder, 0o755) == 0
            for file in files where done {
                try? manager.createDirectory(atPath: (file.path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                done = write(file.data, to: file.path, mode: file.mode)
            }
            outcome = done ? "helper and daemon installed" : "could not install the helper, uid \(geteuid()): \(String(cString: strerror(errno)))"
        }
        if elevated { install() } else { privileged(install) }
        log(outcome)
        return outcome == "helper and daemon installed"
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

/// The window of an app inside the Dopamine app. Dopamine's app delegate answers for scenes,
/// so iOS gives the app one even without a scene configuration in Info.plist, and shows only
/// windows that belong to it: the window joins the scene as soon as there is one.
enum AccessWindow {
    static func show(_ window: UIWindow) {
        window.makeKeyAndVisible()
        guard #available(iOS 13, *) else { return }
        func attach(_ scene: UIScene?) {
            guard let scene = scene as? UIWindowScene, window.windowScene == nil else { return }
            window.windowScene = scene
            window.frame = scene.coordinateSpace.bounds
            window.makeKeyAndVisible()
        }
        attach(UIApplication.shared.connectedScenes.first { $0 is UIWindowScene })
        NotificationCenter.default.addObserver(forName: UIScene.willConnectNotification, object: nil, queue: .main) { attach($0.object as? UIScene) }
    }
}
