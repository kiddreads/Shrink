import AVFoundation
import UIKit

struct VideoInfo {
    var url: URL
    var source: SourceInfo
    var codecName: String
    var bitDepth = 8
    var isHDR = false
    var thumbnail: UIImage?
    var name: String { url.lastPathComponent }
}

enum VideoInfoError: LocalizedError {
    case noVideoTrack
    var errorDescription: String? { "That file doesn't contain a video track." }
}

enum VideoInfoLoader {
    static func load(url: URL) async throws -> VideoInfo {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw VideoInfoError.noVideoTrack }
        let (natural, transform, fps, formats, characteristics) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions, .mediaCharacteristics)
        // naturalSize already includes pixel aspect ratio and clean aperture.
        let display = natural.applying(transform)
        let hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0

        var codec = "Unknown"
        var bits = 8
        if let fd = formats.first {
            if let n = (CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? NSNumber)?.intValue { bits = n }
            codec = codecName(CMFormatDescriptionGetMediaSubType(fd))
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 800, height: 800)
        let at = CMTime(seconds: min(1, max(duration / 2, 0)), preferredTimescale: 600)
        let thumb = (try? await generator.image(at: at).image).map(UIImage.init(cgImage:))

        let info = SourceInfo(bytes: bytes, duration: duration,
                              width: Int(abs(display.width).rounded()), height: Int(abs(display.height).rounded()),
                              fps: Double(fps), hasAudio: hasAudio)
        return VideoInfo(url: url, source: info, codecName: codec, bitDepth: bits, isHDR: characteristics.contains(.containsHDRVideo), thumbnail: thumb)
    }

    /// Horizontal stretch for non-square pixels (1 when the pixels are square or unspecified).
    static func pixelAspect(_ fd: CMFormatDescription) -> Double {
        guard let d = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_PixelAspectRatio) as? [String: Any],
              let h = (d[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String] as? NSNumber)?.doubleValue,
              let v = (d[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing as String] as? NSNumber)?.doubleValue,
              h > 0, v > 0 else { return 1 }
        return h / v
    }

    static func codecName(_ code: FourCharCode) -> String {
        switch code {
        case kCMVideoCodecType_H264: return "H.264"
        case kCMVideoCodecType_HEVC: return "HEVC"
        case kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ, kCMVideoCodecType_AppleProRes4444: return "ProRes"
        case kCMVideoCodecType_MPEG4Video: return "MPEG-4"
        case kCMVideoCodecType_JPEG: return "Motion JPEG"
        default:
            let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
            return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
        }
    }
}

enum Format {
    static func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB]
        return f.string(fromByteCount: n)
    }
    static func duration(_ s: Double) -> String {
        let t = Int(s.rounded())
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
    static func bitrate(_ bps: Int) -> String {
        bps >= 1_000_000 ? String(format: "%.1f Mbps", Double(bps) / 1_000_000) : String(format: "%d kbps", Int((Double(bps) / 1000).rounded()))
    }
    static func resolution(_ w: Int, _ h: Int) -> String { "\(w) \u{00D7} \(h)" }
    static func fps(_ f: Double) -> String {
        f.rounded() == f ? String(format: "%.0f fps", f) : String(format: "%.2f fps", f)
    }
    static func remaining(_ s: TimeInterval) -> String {
        if s < 60 { return "\(max(1, Int(s.rounded()))) sec" }
        return "\(Int(s / 60)) min \(Int(s) % 60) sec"
    }
}
