import SwiftUI
import PhotosUI
import AVFoundation
import Photos

enum TargetMode: String, CaseIterable, Identifiable {
    case percent = "Percent smaller"
    case size = "Target size"
    var id: String { rawValue }
}

enum Phase: Equatable {
    case empty, loading, ready, compressing, done
}

enum TargetCheck {
    case ok(PlanOutcome)
    case needsValue
    case tooLarge
    case tooSmall(minimumBytes: Int64)
}

struct VideoFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { file in
            SentTransferredFile(file.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dir = Compressor.workDirectory.appendingPathComponent("input-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent("Video.\(ext)")
            try FileManager.default.copyItem(at: received.file, to: dest)
            return VideoFile(url: dest)
        }
    }
}

@MainActor @Observable
final class AppModel {
    var phase: Phase = .empty
    var video: VideoInfo?
    var mode: TargetMode = .percent
    var percent = 50
    var targetMB: Double?
    var codec: VideoCodec = .hevc
    var keepAudio = true
    var progress: CompressionProgress?
    var result: CompressionResult?
    var errorMessage: String?
    var errorDetails: String?
    var showError = false
    var saveState: SaveState = .idle
    var savedTick = 0

    enum SaveState: Equatable { case idle, saving, saved, denied, failed }

    private var compressor: Compressor?
    private var task: Task<Void, Never>?
    private var scopedURL: URL?
    private var bgTask = UIBackgroundTaskIdentifier.invalid

    // MARK: Target

    var targetBytes: Int64? {
        guard let v = video else { return nil }
        switch mode {
        case .percent: return Int64(Double(v.source.bytes) * (1 - Double(percent) / 100))
        case .size:
            guard let mb = targetMB, mb > 0 else { return nil }
            return Int64(mb * 1_000_000)
        }
    }

    var check: TargetCheck {
        guard let v = video, let target = targetBytes else { return .needsValue }
        if target >= v.source.bytes { return .tooLarge }
        let outcome = BitratePlanner.plan(source: v.source, targetBytes: target, codec: codec, keepAudio: keepAudio)
        return outcome.isFeasible ? .ok(outcome) : .tooSmall(minimumBytes: outcome.minimumBytes)
    }

    var canCompress: Bool { if case .ok = check { return true }; return false }

    var reductionPercent: Int? {
        guard let v = video, let t = targetBytes, v.source.bytes > 0 else { return nil }
        return Int((100 * (1 - Double(t) / Double(v.source.bytes))).rounded())
    }

    // MARK: Loading

    func load(item: PhotosPickerItem) async {
        phase = .loading
        do {
            guard let file = try await item.loadTransferable(type: VideoFile.self) else { throw VideoInfoError.noVideoTrack }
            await open(url: file.url)
        } catch {
            fail(ErrorReport(stage: .load, error: error))
            phase = .empty
        }
    }

    func importFile(_ result: Result<URL, Error>) async {
        switch result {
        case .failure(let e):
            fail(ErrorReport(stage: .load, error: e))
        case .success(let url):
            phase = .loading
            let scoped = url.startAccessingSecurityScopedResource()
            if scoped { scopedURL = url }
            // Copy so the file stays readable after the picker's access ends.
            do {
                let dir = Compressor.workDirectory.appendingPathComponent("input-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let dest = dir.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.copyItem(at: url, to: dest)
                if scoped { url.stopAccessingSecurityScopedResource(); scopedURL = nil }
                await open(url: dest)
            } catch {
                if scoped { url.stopAccessingSecurityScopedResource(); scopedURL = nil }
                fail(ErrorReport(stage: .load, error: error))
                phase = .empty
            }
        }
    }

    func open(url: URL) async {
        do {
            let info = try await VideoInfoLoader.load(url: url)
            video = info
            keepAudio = info.source.hasAudio
            percent = 50
            targetMB = (Double(info.source.bytes) / 2_000_000 * 10).rounded() / 10
            mode = .percent
            phase = .ready
        } catch {
            fail(ErrorReport(stage: .load, error: error))
            phase = .empty
        }
    }

    // MARK: Compressing

    func start() {
        guard let v = video, let target = targetBytes, canCompress else { return }
        phase = .compressing
        progress = CompressionProgress(fraction: 0, pass: 1, maxPasses: Compressor.maxPasses, remaining: nil)
        UIApplication.shared.isIdleTimerDisabled = true
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "Shrink compress") { [weak self] in
            Task { @MainActor in self?.endBackground() }
        }
        let codec = codec, keepAudio = keepAudio
        let compressor = Compressor()
        self.compressor = compressor
        task = Task {
            do {
                let r = try await compressor.compress(url: v.url, info: v.source, targetBytes: target, codec: codec, keepAudio: keepAudio) { p in
                    Task { @MainActor [weak self] in self?.progress = p }
                }
                result = r
                saveState = .idle
                phase = .done
            } catch is CancellationError {
                phase = .ready
            } catch {
                let outcome = BitratePlanner.plan(source: v.source, targetBytes: target, codec: codec, keepAudio: keepAudio)
                let stage = (error as? StageError)?.stage ?? .encode
                fail(ErrorReport(stage: stage, error: error, video: v, plan: outcome.plan, codec: codec, targetBytes: target, keepAudio: keepAudio))
                phase = .ready
            }
            self.compressor = nil
            endBackground()
        }
    }

    func cancel() { task?.cancel() }

    /// Hardware encoding isn't allowed in the background: stop the pass there, restart it when the app is active again.
    func scenePhaseChanged(_ phase: ScenePhase) {
        guard let compressor else { return }
        switch phase {
        case .background:
            compressor.interrupt()
            progress?.paused = true
        case .active:
            compressor.resume()
        default: break
        }
    }

    private func endBackground() {
        UIApplication.shared.isIdleTimerDisabled = false
        if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid }
    }

    // MARK: Result

    func saveToPhotos() async {
        guard let url = result?.url else { return }
        saveState = .saving
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { saveState = .denied; return }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
            saveState = .saved
            savedTick += 1
        } catch {
            saveState = .failed
            fail(ErrorReport(stage: .save, error: error, video: video))
        }
    }

    func reset() {
        task?.cancel()
        if let r = result { try? FileManager.default.removeItem(at: r.url) }
        if let v = video { try? FileManager.default.removeItem(at: v.url.deletingLastPathComponent()) }
        result = nil; video = nil; progress = nil
        saveState = .idle
        phase = .empty
    }

    func fail(_ message: String) {
        errorMessage = message
        errorDetails = message
        showError = true
    }

    func fail(_ report: ErrorReport) {
        report.log()
        errorMessage = report.summary
        errorDetails = report.details
        showError = true
    }
}
