import UIKit

@UIApplicationMain
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private let model = AppModel()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        var frame = UIScreen.main.bounds
        #if targetEnvironment(simulator)
        // UI tests check the iPod touch's 320 × 568 pt layout, which current simulators lack.
        if ProcessInfo.processInfo.arguments.contains("--ipod-size") { frame = CGRect(x: 0, y: 0, width: 320, height: 568) }
        #endif
        let window = UIWindow(frame: frame)
        if #available(iOS 13, *) { window.overrideUserInterfaceStyle = .light }
        window.tintColor = Theme.blue
        window.rootViewController = RootViewController(model: model)
        window.makeKeyAndVisible()
        self.window = window
        model.connect()
        return true
    }
    // As the SwiftUI app did on scene phases: poll while active, stop in the background.
    func applicationDidBecomeActive(_ application: UIApplication) { model.connect() }
    func applicationDidEnterBackground(_ application: UIApplication) { model.disconnectUI() }
}
