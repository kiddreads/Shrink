import Foundation

enum VideoCodec: String, CaseIterable, Identifiable, Sendable {
    case hevc, h264
    var id: String { rawValue }
    var label: String { self == .hevc ? "HEVC" : "H.264" }
    /// Bits per pixel per frame at which the source resolution is kept.
    var keepSizeBitsPerPixel: Double { self == .hevc ? 0.06 : 0.09 }
    /// Lowest bits per pixel per frame the planner will ever plan for.
    var floorBitsPerPixel: Double { self == .hevc ? 0.025 : 0.04 }
}

struct SourceInfo: Equatable, Sendable {
    var bytes: Int64
    var duration: Double
    /// Display size (after the track's preferred transform).
    var width: Int
    var height: Int
    var fps: Double
    var hasAudio: Bool
}

struct EncodePlan: Equatable, Sendable {
    var videoBitrate: Int
    /// 0 means no audio track in the output.
    var audioBitrate: Int
    var width: Int
    var height: Int
    var fps: Double

    func estimatedBytes(duration: Double) -> Int64 {
        Int64(Double(videoBitrate + audioBitrate) * duration / 8 / (1 - BitratePlanner.containerOverhead))
    }
}

struct PlanOutcome: Equatable, Sendable {
    /// The plan to encode. When the target is impossible this is the smallest plan the planner allows.
    var plan: EncodePlan
    var isFeasible: Bool
    var minimumBytes: Int64
}

enum BitratePlanner {
    static let containerOverhead = 0.02
    static let resolutionLadder = [2160, 1440, 1080, 720, 540, 480, 360]
    static let minimumVideoBitrate = 80_000
    /// (total bits per second at or above, audio bitrate)
    static let audioTiers: [(Int, Int)] = [(1_000_000, 128_000), (500_000, 96_000), (250_000, 64_000), (0, 48_000)]

    static func plan(source: SourceInfo, targetBytes: Int64, codec: VideoCodec, keepAudio: Bool) -> PlanOutcome {
        let duration = max(source.duration, 0.1)
        let srcFps = source.fps > 0 ? source.fps : 30
        let hasAudio = source.hasAudio && keepAudio
        let sizes = candidateSizes(width: source.width, height: source.height)
        let smallest = sizes.last!

        // Minimum achievable: smallest size at the floor bitrate, capped fps, lowest audio tier.
        let minFps = min(srcFps, 30)
        let floorVideo = max(minimumVideoBitrate, Int((codec.floorBitsPerPixel * Double(smallest.w * smallest.h) * minFps).rounded(.up)))
        let minAudio = hasAudio ? audioTiers.last!.1 : 0
        let minBytes = Int64((Double(floorVideo + minAudio) * duration / 8 / (1 - containerOverhead)).rounded(.up))

        let totalBps = Double(targetBytes) * 8 * (1 - containerOverhead) / duration
        let feasible = targetBytes >= minBytes

        // Audio tier: the highest the budget supports that still leaves the floor for video.
        var audio = 0
        if hasAudio {
            let allowed = audioTiers.first { totalBps >= Double($0.0) }!.1
            let candidates = audioTiers.map(\.1).filter { $0 <= allowed }
            audio = candidates.first { Int(totalBps) - $0 >= floorVideo } ?? audioTiers.last!.1
        }
        let videoBps = max(Int(totalBps) - audio, floorVideo)

        if !feasible {
            let plan = EncodePlan(videoBitrate: floorVideo, audioBitrate: minAudio, width: smallest.w, height: smallest.h, fps: minFps)
            return PlanOutcome(plan: plan, isFeasible: false, minimumBytes: minBytes)
        }

        // fps: cap at 30 only when keeping the source size and rate would be too thin.
        let original = sizes[0]
        let bppAtSource = Double(videoBps) / (Double(original.w * original.h) * srcFps)
        let tight = bppAtSource < codec.keepSizeBitsPerPixel
        let fps = (tight && srcFps > 30) ? 30 : srcFps

        var chosen = smallest
        for size in sizes {
            let bpp = Double(videoBps) / (Double(size.w * size.h) * fps)
            if bpp >= codec.keepSizeBitsPerPixel { chosen = size; break }
        }
        let plan = EncodePlan(videoBitrate: videoBps, audioBitrate: audio, width: chosen.w, height: chosen.h, fps: fps)
        return PlanOutcome(plan: plan, isFeasible: true, minimumBytes: minBytes)
    }

    /// Source size first, then each ladder step below it. Keeps aspect, even dimensions, never upscales.
    static func candidateSizes(width: Int, height: Int) -> [(w: Int, h: Int)] {
        let w = max(width, 2), h = max(height, 2)
        let short = min(w, h)
        var out: [(w: Int, h: Int)] = [(even(w), even(h))]
        for step in resolutionLadder where step < short {
            let scale = Double(step) / Double(short)
            out.append((even(Int(Double(w) * scale)), even(Int(Double(h) * scale))))
        }
        return out
    }

    private static func even(_ v: Int) -> Int { max(2, v - v % 2) }
}
