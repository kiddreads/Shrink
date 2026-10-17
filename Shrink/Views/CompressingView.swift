import SwiftUI

struct CompressingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let p = model.progress ?? CompressionProgress(fraction: 0, pass: 1, maxPasses: Compressor.maxPasses, remaining: nil)
        Form {
            Section {
                ProgressView(value: p.fraction) {
                    Text("Compressing")
                } currentValueLabel: {
                    Text(p.fraction, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
                LabeledContent("Time remaining") {
                    Text(p.remaining.map(Format.remaining) ?? "Estimating\u{2026}").monospacedDigit()
                }
                if p.paused {
                    Label("Paused while Shrink was in the background", systemImage: "pause.circle")
                        .foregroundStyle(.secondary)
                }
                if p.pass > 1 {
                    LabeledContent("Pass", value: "\(p.pass) of up to \(p.maxPasses)")
                }
            } footer: {
                Text("Shrink checks the finished file against your target and re-encodes if it's off. Keep the app open for the fastest result.")
            }
            Section {
                Button("Cancel", role: .cancel) { model.cancel() }
                    .frame(maxWidth: .infinity)
            }
        }
    }
}
