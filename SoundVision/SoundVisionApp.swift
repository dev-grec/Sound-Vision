import SwiftUI

@main
struct SoundVisionApp: App {
    @State private var model = AppModel()

    init() {
        GameTargetComponent.registerComponent()
    }

    var body: some Scene {
        WindowGroup(id: AppModel.launcherWindowID) {
            LauncherView()
                .environment(model)
        }
        .defaultSize(width: 560, height: 720)

        ImmersiveSpace(id: AppModel.immersiveSpaceID) {
            ImmersiveRootView()
                .environment(model)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
