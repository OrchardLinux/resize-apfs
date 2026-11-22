import UIKit

@UIApplicationMain
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private let model = AppModel()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
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
