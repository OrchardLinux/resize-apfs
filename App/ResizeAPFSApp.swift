import SwiftUI
import ResizeCore

@main
struct ResizeAPFSApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task { model.connect() }
                .onChange(of: scenePhase) { phase in
                    if phase == .active { model.connect() }
                    else if phase == .background { model.disconnectUI() }
                }
        }
    }
}
