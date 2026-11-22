import Foundation
import Darwin
import ResizeCore

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
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
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
/// does, through LaunchServices. Only bundles directly in /Applications.
public enum AppRegistration {
    public struct Bundle: Equatable {
        public var path: String
        public var identifier: String
    }

    public static func validate(_ path: String) throws -> Bundle {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard path.hasPrefix("/"), url.path == path,
              url.deletingLastPathComponent().path == "/Applications", url.pathExtension == "app" else {
            throw ResizeError("Only an app bundle directly in /Applications can be registered.")
        }
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
        return Bundle(path: path, identifier: identifier)
    }

    public static func register(_ path: String) throws {
        let bundle = try validate(path)
        #if os(iOS)
        let workspace = try defaultWorkspace()
        // The record uicache writes for a system app in /Applications.
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
    /// so an interrupted earlier session can always be cleaned up.
    public static func unregister(_ path: String) throws {
        let bundle = try validate(path)
        #if os(iOS)
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
