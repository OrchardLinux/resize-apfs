import Foundation
import Darwin
import ResizeCore
import NativeSystem

/// The iOS 12-14 (checkra1n) route: the app and helper are copied in for one
/// session (scripts/checkra1n_route.py, Device/README.md). The helper then
/// trusts the session's app executable instead of the palera1n overlay's.
public enum SessionTrust {
    /// The app executable this session's helper serves. It must be a regular
    /// file owned by the helper's user (root on the device) that nobody else can
    /// change, in a directory nobody else can change, because the helper grants
    /// the process running it the storage API.
    public static func validatedUIPath(_ path: String) throws -> String {
        guard path.hasPrefix("/") else { throw ResizeError("--ui-path must be an absolute path.") }
        // realpath(3), not resolvingSymlinksInPath: on iOS, Foundation drops the
        // leading /private, while the kernel reports the app as /private/var/...,
        // so the helper would refuse the app's connection.
        guard let real = realpath(path, nil) else { throw ResizeError("--ui-path \(path) does not exist.") }
        let resolved = String(cString: real)
        free(real)
        try requireProtected(resolved, directory: false)
        try requireProtected((resolved as NSString).deletingLastPathComponent, directory: true)
        return resolved
    }

    private static func requireProtected(_ path: String, directory: Bool) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw ResizeError("Cannot inspect \(path): \(String(cString: strerror(errno))).") }
        let kind = info.st_mode & S_IFMT
        guard kind == (directory ? S_IFDIR : S_IFREG) else {
            throw ResizeError("\(path) is not a \(directory ? "directory" : "regular file").")
        }
        guard info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else {
            throw ResizeError("\(path) must belong to the helper's user and must not be writable by others.")
        }
    }
}

/// Adds the session's app to the home screen and removes it again, as `uicache`
/// does, through LaunchServices. Only bundles directly in `folder`.
///
/// The folder is on the data partition: a stock checkra1n boot mounts the system
/// snapshot read-only, and the session must not change the system partition. A
/// system app outside /Applications is what checkra1n itself registers on every
/// boot (its loader, /var/binpack/Applications/loader.app, via `uicache --path`).
public enum AppRegistration {
    /// The session folder (scripts/checkra1n_route.py). Its real path: the kernel
    /// reports the app's executable under /private/var, not through the /var link.
    public static let folder = "/private/var/ResizeAPFS"

    public struct Bundle: Equatable {
        public var path: String
        public var identifier: String
        public var executable: String
    }

    public static func validate(_ path: String) throws -> Bundle {
        // Compared as text, not standardized: on iOS, Foundation's standardizing
        // drops the leading /private of /private/var paths, so the folder never matched.
        let name = String(path.dropFirst(folder.count + 1))
        guard path.hasPrefix(folder + "/"), name.hasSuffix(".app"), name.count > 4, !name.contains("/") else {
            throw ResizeError("Only an app bundle directly in \(folder) can be registered.")
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw ResizeError("\(path) is not an app bundle directory.")
        }
        guard let plist = NSDictionary(contentsOf: url.appendingPathComponent("Info.plist")),
              let identifier = plist["CFBundleIdentifier"] as? String, !identifier.isEmpty,
              let executable = plist["CFBundleExecutable"] as? String, !executable.isEmpty,
              !executable.contains("/") else {
            throw ResizeError("\(path) has no valid Info.plist.")
        }
        var binary = stat()
        guard lstat(url.appendingPathComponent(executable).path, &binary) == 0, binary.st_mode & S_IFMT == S_IFREG else {
            throw ResizeError("\(path) has no app executable.")
        }
        return Bundle(path: path, identifier: identifier, executable: executable)
    }

    public static func register(_ path: String) throws {
        let bundle = try validate(path)
        #if os(iOS)
        let workspace = try defaultWorkspace()
        // The record uicache writes for a system app (also outside /Applications).
        let record: NSDictionary = [
            "ApplicationType": "System",
            "CFBundleIdentifier": bundle.identifier,
            "CodeInfoIdentifier": bundle.identifier,
            "CompatibilityState": 0,
            "IsContainerized": false,
            "IsDeletable": false,
            "Path": bundle.path,
            "SignerOrganization": "Apple Inc.",
            "SignatureVersion": 132352,
            "SignerIdentity": "Apple iPhone OS Application Signing",
            "IsAdHocSigned": true,
            "LSInstallType": 1,
            "HasMIDBasedSINF": 0,
            "MissingSINF": 0,
            "FamilyID": 0,
            "IsOnDemandInstallCapable": 0,
        ]
        guard call(workspace, "registerApplicationDictionary:", record) else {
            throw ResizeError("LaunchServices did not register \(bundle.identifier).")
        }
        guard isInstalled(workspace, bundle.identifier) else {
            throw ResizeError("\(bundle.identifier) is not on the home screen after registering.")
        }
        #else
        throw ResizeError("Registering apps is only possible on iOS (\(bundle.identifier)).")
        #endif
    }

    /// Succeeds when the app is no longer registered, also when it never was,
    /// so an interrupted earlier session can always be cleaned up. A running app
    /// is quit first (`AppQuit`): unregistered while it runs, or while SpringBoard
    /// is still handling its exit, it leaves a black screen the Home button does
    /// not leave (iPod touch 6, iOS 12.4).
    public static func unregister(_ path: String) throws {
        let bundle = try validate(path)
        #if os(iOS)
        try AppQuit.quit(bundle)
        let workspace = try defaultWorkspace()
        guard isInstalled(workspace, bundle.identifier) else { return }
        _ = call(workspace, "unregisterApplication:", URL(fileURLWithPath: bundle.path) as NSURL)
        guard !isInstalled(workspace, bundle.identifier) else {
            throw ResizeError("LaunchServices still lists \(bundle.identifier) after unregistering.")
        }
        #else
        throw ResizeError("Unregistering apps is only possible on iOS (\(bundle.identifier)).")
        #endif
    }

    #if os(iOS)
    private static func defaultWorkspace() throws -> NSObject {
        // LSApplicationWorkspace lives in MobileCoreServices up to iOS 13 and
        // CoreServices from iOS 14; loading whichever exists is enough.
        _ = dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW)
        _ = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW)
        guard let type = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
              let workspace = type.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() as? NSObject else {
            throw ResizeError("LaunchServices is not available.")
        }
        return workspace
    }

    private static func call(_ workspace: NSObject, _ name: String, _ argument: AnyObject) -> Bool {
        let selector = NSSelectorFromString(name)
        guard workspace.responds(to: selector) else { return false }
        typealias Method = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        return unsafeBitCast(workspace.method(for: selector), to: Method.self)(workspace, selector, argument)
    }

    private static func isInstalled(_ workspace: NSObject, _ identifier: String) -> Bool {
        call(workspace, "applicationIsInstalled:", identifier as NSString)
    }
    #endif
}

/// Quits an app the way the app switcher does: FrontBoard (inside SpringBoard)
/// terminates it, so SpringBoard tears down its scene and returns to the Home
/// Screen itself. Done when the app's process is gone from the process list and
/// FrontBoard no longer reports a process for it; only then may the app be
/// unregistered. Every wait has a deadline.
public enum AppQuit {
    /// What the quit needs from the system; the device implementation is `system`.
    public struct System {
        /// 1 running, 0 not, -1 unknown (`raf_process_running`).
        public var processRunning: () -> Int32
        /// FrontBoard's process id for the app (0: none), nil when FrontBoard cannot be asked.
        public var frontBoardPID: () -> Int32?
        /// Ask FrontBoard to terminate the app; false when it could not be asked.
        public var terminate: () -> Bool
        /// SIGKILL the app's process, for when FrontBoard could not be asked or did not end it.
        public var kill: () -> Void
        public var now: () -> TimeInterval
        public var sleep: (TimeInterval) -> Void
        public init(processRunning: @escaping () -> Int32, frontBoardPID: @escaping () -> Int32?,
                    terminate: @escaping () -> Bool, kill: @escaping () -> Void,
                    now: @escaping () -> TimeInterval, sleep: @escaping (TimeInterval) -> Void) {
            self.processRunning = processRunning; self.frontBoardPID = frontBoardPID
            self.terminate = terminate; self.kill = kill; self.now = now; self.sleep = sleep
        }
    }

    /// How long FrontBoard's termination, and then a kill, each get to take effect.
    public static let deadline: TimeInterval = 10
    static let interval: TimeInterval = 0.1

    /// True when neither the process list nor FrontBoard knows a process of the app.
    static func gone(_ system: System) -> Bool {
        system.processRunning() == 0 && (system.frontBoardPID() ?? 0) <= 0
    }

    static func wait(_ system: System) -> Bool {
        let end = system.now() + deadline
        while true {
            if gone(system) { return true }
            if system.now() >= end { return false }
            system.sleep(interval)
        }
    }

    /// Quits the app if it runs; throws when it still runs after both deadlines.
    public static func quit(_ name: String, using system: System) throws {
        if gone(system) { return }
        if system.terminate(), wait(system) { return }
        system.kill()
        guard wait(system) else {
            throw ResizeError("\(name) is still running after it was asked to quit. It was not removed from the home screen.")
        }
    }

    #if os(iOS)
    public static func quit(_ bundle: AppRegistration.Bundle) throws {
        try quit(bundle.identifier, using: system(bundle))
    }

    static func system(_ bundle: AppRegistration.Bundle) -> System {
        let service = frontBoardService()
        let identifier = bundle.identifier as NSString
        return System(
            processRunning: { raf_process_running(bundle.executable) },
            frontBoardPID: {
                let selector = NSSelectorFromString("pidForApplication:")
                guard let service, service.responds(to: selector) else { return nil }
                typealias Method = @convention(c) (AnyObject, Selector, NSString) -> Int32
                return unsafeBitCast(service.method(for: selector), to: Method.self)(service, selector, identifier)
            },
            terminate: {
                // FBSSystemService, iOS 8 and later; needs com.apple.multitasking.termination.
                let selector = NSSelectorFromString("terminateApplication:forReason:andReport:withDescription:")
                guard let service, service.responds(to: selector) else { return false }
                typealias Method = @convention(c) (AnyObject, Selector, NSString, Int, ObjCBool, NSString?) -> Void
                // Reason 1: the user quit it, as from the app switcher. No crash report.
                unsafeBitCast(service.method(for: selector), to: Method.self)(service, selector, identifier, 1, false,
                                                                            "Resize APFS session ended" as NSString)
                return true
            },
            kill: {
                let pid = raf_process_pid(bundle.executable)
                if pid > 0 { _ = Darwin.kill(pid, SIGKILL) }
            },
            now: { ProcessInfo.processInfo.systemUptime },
            sleep: { Thread.sleep(forTimeInterval: $0) })
    }

    private static func frontBoardService() -> NSObject? {
        _ = dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_NOW)
        guard let type = NSClassFromString("FBSSystemService") as? NSObject.Type else { return nil }
        return type.perform(NSSelectorFromString("sharedService"))?.takeUnretainedValue() as? NSObject
    }
    #endif
}
