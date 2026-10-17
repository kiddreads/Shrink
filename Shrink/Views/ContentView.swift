import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var pickerItem: PhotosPickerItem?
    @State private var showImporter = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Group {
                switch model.phase {
                case .empty: EmptyStateView(pickerItem: $pickerItem, showImporter: $showImporter)
                case .loading: ProgressView("Loading\u{2026}")
                case .ready: SetupView()
                case .compressing: CompressingView()
                case .done: ResultView()
                }
            }
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Shrink")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            pickerItem = nil
            Task { await model.load(item: item) }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.movie]) { result in
            Task { await model.importFile(result) }
        }
        .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(phase) }
        .alert("Something went wrong", isPresented: $model.showError) {
            Button("Copy Details") { UIPasteboard.general.string = model.errorDetails ?? model.errorMessage }
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct EmptyStateView: View {
    @Binding var pickerItem: PhotosPickerItem?
    @Binding var showImporter: Bool

    var body: some View {
        ContentUnavailableView {
            Label("No Video", systemImage: "film")
        } description: {
            Text("Choose a video to make it smaller.")
        } actions: {
            VStack(spacing: 12) {
                PhotosPicker(selection: $pickerItem, matching: .videos) {
                    Label("Choose Video", systemImage: "photo.on.rectangle")
                        .frame(minWidth: 180)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    showImporter = true
                } label: {
                    Label("Browse Files", systemImage: "folder")
                        .frame(minWidth: 180)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
    }
}
