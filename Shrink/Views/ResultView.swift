import SwiftUI
import AVKit

struct ResultView: View {
    @Environment(AppModel.self) private var model
    @State private var player: AVPlayer?

    var body: some View {
        if let result = model.result, let video = model.video {
            let before = video.source.bytes
            let reduction = before > 0 ? Int((100 * (1 - Double(result.bytes) / Double(before))).rounded()) : 0
            Form {
                Section {
                    VideoPlayer(player: player)
                        .aspectRatio(CGFloat(result.plan.width) / CGFloat(result.plan.height), contentMode: .fit)
                        .listRowInsets(EdgeInsets())
                        .frame(maxHeight: 360)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.black)
                }
                Section {
                    LabeledContent("Before", value: Format.bytes(before))
                    LabeledContent("After", value: Format.bytes(result.bytes))
                    LabeledContent("Reduction", value: "\(reduction)% smaller")
                    LabeledContent("Resolution", value: Format.resolution(result.plan.width, result.plan.height))
                    LabeledContent("Bitrate", value: Format.bitrate(result.plan.videoBitrate + result.plan.audioBitrate))
                } footer: {
                    if !result.hitTarget {
                        Label("This couldn't get under the target (\(Format.bytes(result.targetBytes))). Try a slightly larger one.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    } else if Double(result.bytes) < Double(result.targetBytes) * 0.85 {
                        Text("Landed under the target; the encoder couldn't use all of it.")
                    }
                }
                Section {
                    Button {
                        Task { await model.saveToPhotos() }
                    } label: {
                        Label(saveTitle, systemImage: model.saveState == .saved ? "checkmark.circle.fill" : "square.and.arrow.down")
                    }
                    .disabled(model.saveState == .saving || model.saveState == .saved)
                    ShareLink(item: result.url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                } footer: {
                    switch model.saveState {
                    case .denied: Text("Allow adding to Photos in Settings to save.").foregroundStyle(.red)
                    case .failed: Text("Couldn't save to Photos.").foregroundStyle(.red)
                    default: EmptyView()
                    }
                }
                Section {
                    Button("Compress Another") { model.reset() }
                }
            }
            .sensoryFeedback(.success, trigger: model.savedTick)
            .onAppear { if player == nil { player = AVPlayer(url: result.url) } }
            .onDisappear { player?.pause() }
        }
    }

    private var saveTitle: String {
        switch model.saveState {
        case .saving: "Saving\u{2026}"
        case .saved: "Saved to Photos"
        default: "Save to Photos"
        }
    }
}
