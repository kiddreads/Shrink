import SwiftUI

struct SetupView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        if let video = model.video {
            Form {
                Section("Source") {
                    HStack(spacing: 14) {
                        Thumbnail(image: video.thumbnail)
                            .frame(width: 112, height: 72)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(video.name).lineLimit(2)
                            Text(Format.bytes(video.source.bytes)).font(.title3.weight(.semibold))
                        }
                    }
                    LabeledContent("Duration", value: Format.duration(video.source.duration))
                    LabeledContent("Resolution", value: Format.resolution(video.source.width, video.source.height))
                    LabeledContent("Frame rate", value: Format.fps(video.source.fps))
                    LabeledContent("Codec", value: video.codecName)
                }

                Section {
                    Picker("Mode", selection: $model.mode) {
                        ForEach(TargetMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if model.mode == .percent {
                        PercentRows()
                    } else {
                        SizeRows()
                    }
                } header: {
                    Text("Target")
                } footer: {
                    TargetFooter()
                }

                if let details = model.errorDetails {
                    Section {
                        ShareLink("Share Last Error Details", item: details)
                    } footer: {
                        Text("Send this to whoever is debugging Shrink.")
                    }
                }

                Section("Options") {
                    Picker("Codec", selection: $model.codec) {
                        ForEach(VideoCodec.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Keep audio", isOn: $model.keepAudio)
                        .disabled(!video.source.hasAudio)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    model.start()
                } label: {
                    Text("Compress").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canCompress)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Change Video") { model.reset() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                }
            }
        }
    }
}

struct Thumbnail: View {
    let image: UIImage?
    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary).overlay { Image(systemName: "film").foregroundStyle(.secondary) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct PercentRows: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let src = model.video?.source.bytes ?? 0
        VStack(alignment: .leading, spacing: 8) {
            Text("Make it \(model.percent)% smaller")
            Slider(value: Binding(get: { Double(model.percent) }, set: { model.percent = Int($0.rounded()) }), in: 1...95, step: 1)
        }
        .padding(.vertical, 4)
        HStack {
            Text("Percent")
            Spacer()
            TextField("Percent", value: Binding(get: { model.percent }, set: { model.percent = min(95, max(1, $0)) }), format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 80)
            Text("%").foregroundStyle(.secondary)
        }
        LabeledContent("Result") {
            Text("\(Format.bytes(src)) \u{2192} \(Format.bytes(model.targetBytes ?? 0))")
                .monospacedDigit()
        }
    }
}

private struct SizeRows: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack {
            Text("Target size")
            Spacer()
            TextField("MB", value: $model.targetMB, format: .number.precision(.fractionLength(0...2)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 100)
            Text("MB").foregroundStyle(.secondary)
        }
        LabeledContent("Reduction") {
            if let r = model.reductionPercent, case .ok = model.check {
                Text("\(r)% smaller").monospacedDigit()
            } else {
                Text("\u{2014}").foregroundStyle(.secondary)
            }
        }
    }
}

private struct TargetFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.check {
        case .ok(let outcome):
            let p = outcome.plan
            Text("Output: \(Format.resolution(p.width, p.height)), \(Format.fps(p.fps)), \(Format.bitrate(p.videoBitrate)) video")
        case .needsValue:
            Text("Enter a size in MB.")
        case .tooLarge:
            Label("That's not smaller than the original. Pick a smaller size.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .tooSmall(let minBytes):
            Label("Too small for a watchable video. The smallest possible is \(Format.bytes(minBytes)).", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }
}
