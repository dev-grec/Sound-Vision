import SwiftUI

/// Content of the mixed immersive space: the game or the Glass Lab, chosen in the launcher.
struct ImmersiveRootView: View {
    @Environment(AppModel.self) private var model

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
        }
    }
}
