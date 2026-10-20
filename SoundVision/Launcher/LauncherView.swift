import RhythmCore
import SwiftUI

/// The 2D window: start the test map or the Glass Lab, debug toggles, input offset, last result.
struct LauncherView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    if let entry = model.selectedMap {
                        LabeledContent(entry.beatmap.meta.title) {
                            Text("\(entry.beatmap.notes.count) notes · \(Int(entry.beatmap.timing.bpm)) BPM")
                        }
                        ForEach(Array(entry.report.issues.enumerated()), id: \.offset) { _, issue in
                            Text(issue.description)
                                .font(.caption)
                                .foregroundStyle(issue.severity == .error ? .red : .orange)
                        }
                    }
                    ForEach(Array(model.library.failures.enumerated()), id: \.offset) { _, failure in
                        Text("\(failure.name): \(failure.message)").font(.caption).foregroundStyle(.red)
                    }
                    if model.spaceState == .closed {
                        Button("Play Test Map") { Task { await open(.game) } }
                            .disabled(!(model.selectedMap?.report.isPlayable ?? false))
                        Button("Glass Lab (rendering prototype)") { Task { await open(.glassLab) } }
                    } else {
                        if !model.liveStatus.isEmpty {
                            Text(model.liveStatus).monospacedDigit()
                        }
                        Button("Exit", role: .destructive) { Task { await dismissImmersiveSpace() } }
                            .disabled(model.spaceState != .open)
                    }
                }

                Section("Settings") {
                    Toggle("Autoplay (scripted perfect input)", isOn: $model.autoplay)
                        .disabled(model.spaceState != .closed)
                    VStack(alignment: .leading) {
                        Text("Input offset: \(Int(model.tuning.inputOffsetMs)) ms")
                            .monospacedDigit()
                        Slider(value: $model.tuning.inputOffsetMs, in: model.tuning.inputOffsetRangeMs, step: 5)
                        Text("Positive if your pinches register late.").font(.caption).foregroundStyle(.secondary)
                    }
                    .disabled(model.spaceState != .closed)
                    Picker("Glass variant", selection: $model.glassVariant) {
                        ForEach(GlassVariant.allCases) { Text($0.label).tag($0) }
                    }
                }

                if let result = model.lastResult {
                    Section("Last result: \(result.title)") {
                        LabeledContent("Score", value: "\(result.score)")
                        LabeledContent("Accuracy", value: result.accuracy.formatted(.percent.precision(.fractionLength(1))))
                        LabeledContent("Max combo", value: "\(result.maxCombo) / \(result.totalNotes)")
                        ForEach(Judgment.allCases, id: \.self) { j in
                            LabeledContent(j.displayName, value: "\(result.counts[j, default: 0])")
                        }
                    }
                }
            }
            .navigationTitle("Sound Vision")
        }
        .task {
            if let mode = model.autostartMode, model.spaceState == .closed {
                await open(mode)
            }
        }
    }

    private func open(_ mode: AppModel.Mode) async {
        model.mode = mode
        model.spaceState = .opening
        switch await openImmersiveSpace(id: AppModel.immersiveSpaceID) {
        case .opened:
            break // ImmersiveRootView sets .open when it appears
        default:
            model.spaceState = .closed
        }
    }
}
