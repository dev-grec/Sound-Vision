import SwiftUI

/// Content of the mixed immersive space: the game or the Glass Lab, chosen in the launcher.
struct ImmersiveRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            switch model.mode {
            case .game: GameView()
            case .glassLab: GlassLabView()
            }
        }
        .onAppear { model.spaceState = .open }
        .onDisappear {
            model.spaceState = .closed
            model.liveStatus = ""
            // The launcher was dismissed for play (LauncherView.open); bring it back with the result.
            if model.launcherHidden {
                model.launcherHidden = false
                openWindow(id: AppModel.launcherWindowID)
            }
        }
    }
}
