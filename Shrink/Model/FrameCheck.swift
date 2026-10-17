import AVFoundation
import CoreVideo

/// Per-frame brightness check: no output frame may be black (or far darker) when its source frame isn't.
struct FrameLuma: Sendable {
    var pts: Double
    var luma: Double   // 0...1, video-range normalised
}

struct FrameCheckReport: Sendable {
    var frames: Int
    var missing: Int
    var failures: [String]
    var blackSourceFrames: Int
    var blackOutputFrames: Int
    var minRatio: Double       // lowest output/source luma over frames whose source luma > 0.1
    var passed: Bool { failures.isEmpty && missing <= 1 }
    var summary: String {
        "frames=\(frames) missing=\(missing) failures=\(failures.count) blackSrc=\(blackSourceFrames) blackOut=\(blackOutputFrames) minRatio=\(String(format: "%.2f", minRatio))"
    }
}

enum FrameCheck {
    static let blackLuma = 0.03
    static let sourceNotBlack = 0.06
    static let darkerRatio = 0.5
    static let darkerMinSource = 0.1

    /// Mean luma of a decoded frame, sampled on a coarse grid. Handles 8-bit and 10-bit biplanar 4:2:0 and BGRA.
    static func meanLuma(_ pb: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let format = CVPixelBufferGetPixelFormatType(pb)
        var sum = 0.0, n = 0.0
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return 0 }
            let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            let tenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            let full = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            let sx = max(1, w / 64), sy = max(1, h / 36)
            for y in stride(from: 0, to: h, by: sy) {
                let row = base.advanced(by: y * rowBytes)
                for x in stride(from: 0, to: w, by: sx) {
                    let v: Double
                    if tenBit { v = Double(row.load(fromByteOffset: x * 2, as: UInt16.self) >> 6) / 1023 }
                    else { v = Double(row.load(fromByteOffset: x, as: UInt8.self)) / 255 }
                    sum += v; n += 1
                }
            }
            let mean = sum / max(n, 1)
            return full ? mean : max(0, (mean - 16.0 / 255) / (219.0 / 255))
        case kCVPixelFormatType_32BGRA:
            guard let base = CVPixelBufferGetBaseAddress(pb) else { return 0 }
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            let rowBytes = CVPixelBufferGetBytesPerRow(pb)
            let sx = max(1, w / 64), sy = max(1, h / 36)
            for y in stride(from: 0, to: h, by: sy) {
                let row = base.advanced(by: y * rowBytes)
                for x in stride(from: 0, to: w, by: sx) {
                    let b = Double(row.load(fromByteOffset: x * 4, as: UInt8.self))
                    let g = Double(row.load(fromByteOffset: x * 4 + 1, as: UInt8.self))
                    let r = Double(row.load(fromByteOffset: x * 4 + 2, as: UInt8.self))
                    sum += (0.0722 * b + 0.7152 * g + 0.2126 * r) / 255; n += 1
                }
            }
            return sum / max(n, 1)
        default:
            return 0.5
        }
    }

    /// Decodes every frame of a file (8-bit 4:2:0) and returns each frame's luma. Runs off the cooperative pool.
    static func lumas(of url: URL) async throws -> [FrameLuma] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
        return try await Task.detached(priority: .utility) {
            let reader = try AVAssetReader(asset: asset)
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ])
            out.alwaysCopiesSampleData = false
            reader.add(out)
            guard reader.startReading() else { throw reader.error ?? CompressorError.brokenOutput }
            var result: [FrameLuma] = []
            var more = true
            while more {
                more = autoreleasepool {
                    guard let sb = out.copyNextSampleBuffer() else { return false }
                    if let pb = CMSampleBufferGetImageBuffer(sb) {
                        result.append(FrameLuma(pts: CMSampleBufferGetPresentationTimeStamp(sb).seconds, luma: meanLuma(pb)))
                    }
                    return true
                }
            }
            if reader.status == .failed { throw reader.error ?? CompressorError.brokenOutput }
            return result.sorted { $0.pts < $1.pts }
        }.value
    }

    /// Compares each output frame against the reference frame with the same PTS.
    static func compare(reference: [FrameLuma], output: [FrameLuma], tolerance: Double, requireAllReferenceMatched: Bool = true) -> FrameCheckReport {
        let ref = reference.sorted { $0.pts < $1.pts }
        let out = output.sorted { $0.pts < $1.pts }
        var failures: [String] = []
        var blackSrc = 0, blackOut = 0, minRatio = Double.infinity
        var j = 0

        func nearest(in list: [FrameLuma], to t: Double, from start: inout Int) -> FrameLuma? {
            while start + 1 < list.count && abs(list[start + 1].pts - t) <= abs(list[start].pts - t) { start += 1 }
            guard start < list.count, abs(list[start].pts - t) <= tolerance else { return nil }
            return list[start]
        }

        for frame in out {
            guard let r = nearest(in: ref, to: frame.pts, from: &j) else {
                failures.append("output frame at \(String(format: "%.3f", frame.pts))s has no source frame")
                continue
            }
            if r.luma <= sourceNotBlack { blackSrc += 1 }
            if frame.luma <= blackLuma { blackOut += 1 }
            if r.luma > darkerMinSource { minRatio = min(minRatio, frame.luma / r.luma) }
            if frame.luma <= blackLuma && r.luma > sourceNotBlack {
                failures.append("black frame at \(String(format: "%.3f", frame.pts))s (source luma \(String(format: "%.2f", r.luma)))")
            } else if r.luma > darkerMinSource && frame.luma < r.luma * darkerRatio {
                failures.append("dark frame at \(String(format: "%.3f", frame.pts))s (\(String(format: "%.2f", frame.luma)) vs source \(String(format: "%.2f", r.luma)))")
            }
        }

        var missing = 0
        if requireAllReferenceMatched {
            var k = 0
            for r in ref where nearest(in: out, to: r.pts, from: &k) == nil { missing += 1 }
            if abs(out.count - ref.count) > 1 { failures.append("frame count \(out.count) vs \(ref.count)") }
        }
        return FrameCheckReport(frames: out.count, missing: missing, failures: failures, blackSourceFrames: blackSrc,
                                blackOutputFrames: blackOut, minRatio: minRatio == .infinity ? 1 : minRatio)
    }
}
