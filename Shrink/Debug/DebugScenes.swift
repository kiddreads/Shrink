#if DEBUG
import Foundation

/// Screenshot support: `-scene <name>` opens a state with a generated sample video.
enum DebugScenes {
    @MainActor
    static func applyLaunchArgument(to model: AppModel) async {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-scene"), i + 1 < args.count else { return }
        let scene = args[i + 1]
        if scene == "empty" { return }
        model.phase = .loading
        let url: URL
        do {
            url = try await SyntheticVideo.cachedURL(name: "shrink-sample", width: 1920, height: 1080, seconds: 5, fps: 30, bitrate: 14_000_000)
            await model.open(url: url)
        } catch { model.fail("Sample failed: \(error.localizedDescription)"); return }
        guard let v = model.video else { return }
        switch scene {
        case "percent": model.percent = 75
        case "mb": model.mode = .size; model.targetMB = 2.5
        case "impossible": model.mode = .size; model.targetMB = 0.05
        case "compressing":
            model.progress = CompressionProgress(fraction: 0.42, pass: 1, maxPasses: 3, remaining: 18)
            model.phase = .compressing
        case "result":
            let target = Int64(Double(v.source.bytes) * 0.5)
            let plan = BitratePlanner.plan(source: v.source, targetBytes: target, codec: .hevc, keepAudio: true).plan
            model.result = CompressionResult(url: url, bytes: Int64(Double(target) * 0.96), targetBytes: target, plan: plan, passes: 1, hitTarget: true)
            model.phase = .done
        default: break
        }
    }
}
#endif
