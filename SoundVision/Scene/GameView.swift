import RealityKit
import RhythmCore
import SwiftUI

/// The play scene: the rotating glass sphere with tap notes, a floating HUD, and look-and-pinch input.
struct GameView: View {
    @Environment(AppModel.self) private var model
    @State private var controller = GameSceneController()
    @State private var loadError: String?

    var body: some View {
        RealityView { content, attachments in
            loadError = controller.load(model: model, into: &content, hud: attachments.entity(for: "hud"))
        } update: { _, _ in
            controller.applyVariant(model.glassVariant)
        } attachments: {
            Attachment(id: "hud") {
                GameHUDView(hud: controller.hud, error: loadError)
            }
        }
        .gesture(
            SpatialTapGesture()
                .targetedToAnyEntity()
                .onEnded { value in controller.handleTap(on: value.entity) }
        )
        // Pinch-and-hold for sliders. minimumDistance 0 reports the press immediately; for a plain note
        // whichever of the two gestures arrives first judges it (RhythmCore ignores the second).
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .targetedToAnyEntity()
                .onChanged { value in controller.handleDrag(value) }
                .onEnded { value in controller.handleDragEnded(value) }
        )
        .onDisappear { controller.stop() }
    }
}

struct GameHUDView: View {
    var hud: GameSceneController.HUD
    var error: String?

    var body: some View {
        VStack(spacing: 6) {
            if let error {
                Text(error).font(.headline).foregroundStyle(.red)
            } else {
                HStack {
                    Text(hud.title).font(.headline)
                    if hud.autoplay {
                        Text("AUTOPLAY")
                            .font(.caption.bold())
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(.orange, in: Capsule())
                    }
                }
                HStack(spacing: 18) {
                    stat("Score", "\(hud.score)")
                    stat("Combo", "\(hud.combo)")
                    stat("Accuracy", hud.accuracy.formatted(.percent.precision(.fractionLength(1))))
                    stat("Notes", "\(hud.judged)/\(hud.total)")
                }
                Text(hud.message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .glassBackgroundEffect()
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            Text(value).font(.title3.monospacedDigit()).bold()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
