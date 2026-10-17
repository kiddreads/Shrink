import SwiftUI

@main
struct ShrinkApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                #if DEBUG
                .task { await DebugScenes.applyLaunchArgument(to: model) }
                #endif
        }
    }
}
