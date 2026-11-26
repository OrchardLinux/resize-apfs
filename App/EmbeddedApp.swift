import UIKit
import ResizeCore

extension StorageAccess.Configuration {
    /// Resize APFS without DFU.
    static let resizeAPFS = StorageAccess.Configuration(
        name: "Resize APFS", state: "ResizeAPFS", folder: "/private/var/ResizeAPFS", label: "dev.omarchy.resize-apfs",
        payloads: [("resize-helper", "/var/jb/usr/libexec/resize-helper")],
        arguments: ["--allow-writes"],
        lock: "/var/root/Library/ResizeAPFS/helper.lock",
        // What sessions of earlier releases (over SSH) left in the folder, and the Orchard
        // installer's helper: both apps are the same app to iOS, so only one is on a device.
        leftovers: ["/private/var/ResizeAPFS/resize-helper", "/private/var/ResizeAPFS/helper.pid", "/private/var/ResizeAPFS/helper.log",
                    "/var/jb/Library/LaunchDaemons/dev.orchard.installer.plist"])
}

/// The app's start inside the Dopamine app: what AppDelegate does for the app booted with
/// DFU, begun by Access/AccessBridge.m once the host app has launched.
@objc(RAFEmbeddedApp) final class EmbeddedApp: NSObject {
    private static var window: UIWindow?
    private static var model: AppModel?

    @objc(startWithBridge:) static func start(bridge: AnyObject) {
        guard window == nil else { return }
        let model = AppModel(access: StorageAccess(bridge: unsafeBitCast(bridge, to: AccessBridge.self), configuration: .resizeAPFS))
        let window = UIWindow(frame: UIScreen.main.bounds)
        if #available(iOS 13, *) { window.overrideUserInterfaceStyle = .dark }
        window.backgroundColor = Theme.background
        window.tintColor = Theme.blue
        window.rootViewController = RootViewController(model: model)
        AccessWindow.show(window)
        self.window = window
        self.model = model
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            model.access?.note("active")
            model.connect()
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            model.access?.note("background")
            model.disconnectUI()
        }
        model.connect()
    }
}
