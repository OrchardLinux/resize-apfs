import Foundation
import Darwin
import NativeSystem

/// Puts the app on the screen without the user looking for it, as Orchard's
/// installer companion does: register it with iOS as soon as iOS takes it
/// (palera1n's daemon does the same, about a minute later), then open it until
/// its process runs. The app is opened once per helper start.
public final class AppOpener: @unchecked Sendable {
    /// palera1n's uicache, on the palera1n route only.
    static let uicache = "/cores/binpack/usr/bin/uicache"

    let appPath: String
    let executableName: String
    let registerWithUICache: Bool

    /// `executable`: the app's executable inside its bundle. `registerWithUICache`:
    /// the palera1n route, where nothing has registered the app yet; the iOS 12-14
    /// session registers it before the helper starts.
    public init(executable: String, registerWithUICache: Bool) {
        appPath = (executable as NSString).deletingLastPathComponent
        executableName = (executable as NSString).lastPathComponent
        self.registerWithUICache = registerWithUICache
    }

    public func start(log: @escaping (String) -> Void = { print($0); fflush(stdout) }) {
        #if os(iOS)
        Thread.detachNewThread { [self] in
            guard let identifier = Bundle(path: appPath)?.bundleIdentifier else {
                log("App opener: no bundle identifier in \(appPath)")
                return
            }
            var lastRegister = Date.distantPast
            var lastOutcome = ""
            // Give up after ten minutes: the user can always open the app from the Home Screen.
            let deadline = Date().addingTimeInterval(600)
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 1)
                if raf_process_running(executableName) == 1 {
                    log("App opener: the app is running")
                    return
                }
                guard installed(identifier) else {
                    if registerWithUICache, Date().timeIntervalSince(lastRegister) > 3,
                       FileManager.default.isExecutableFile(atPath: appPath + "/" + executableName) {
                        lastRegister = Date()
                        log("App opener: registering the app, uicache exit \(spawn([Self.uicache, "-p", appPath]))")
                    }
                    continue
                }
                let viaLaunchServices = open(identifier)
                let viaSpringBoard = viaLaunchServices ? 0 : springBoardLaunch(identifier)
                // A locked device refuses every attempt (Berkay saw SpringBoard 3) until it is unlocked:
                // log the outcome when it changes, not every second.
                let outcome = "LaunchServices \(viaLaunchServices), SpringBoard \(viaSpringBoard)"
                if outcome != lastOutcome {
                    log("App opener: opening the app, \(outcome); retrying every second until the app runs")
                    lastOutcome = outcome
                }
            }
            log("App opener: gave up; the app stays on the Home Screen")
        }
        #endif
    }

    private func workspace() -> NSObject? {
        guard let type = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else { return nil }
        return type.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() as? NSObject
    }

    private func call(_ name: String, _ identifier: String) -> Bool {
        guard let ws = workspace() else { return false }
        let selector = NSSelectorFromString(name)
        guard ws.responds(to: selector) else { return false }
        typealias Call = @convention(c) (AnyObject, Selector, NSString) -> Bool
        return unsafeBitCast(ws.method(for: selector), to: Call.self)(ws, selector, identifier as NSString)
    }

    private func installed(_ identifier: String) -> Bool { call("applicationIsInstalled:", identifier) }
    private func open(_ identifier: String) -> Bool { call("openApplicationWithBundleID:", identifier) }

    /// SpringBoard's own launcher, for when LaunchServices declines.
    private func springBoardLaunch(_ identifier: String) -> Int32 {
        guard let library = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY),
              let symbol = dlsym(library, "SBSLaunchApplicationWithIdentifier") else { return -1 }
        typealias Launch = @convention(c) (CFString, DarwinBoolean) -> Int32
        return unsafeBitCast(symbol, to: Launch.self)(identifier as CFString, false)
    }

    private func spawn(_ argv: [String]) -> Int32 {
        var pid: pid_t = 0
        let args = argv.map { strdup($0) } + [nil]
        defer { args.forEach { free($0) } }
        guard posix_spawn(&pid, argv[0], nil, nil, args, environ) == 0 else { return -1 }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        return status
    }
}
