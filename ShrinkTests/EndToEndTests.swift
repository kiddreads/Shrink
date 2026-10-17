import XCTest
import AVFoundation
@testable import Shrink

final class EndToEndTests: XCTestCase {
    typealias Options = SyntheticVideo.Options

    // MARK: Helpers

    static func quadrants(of url: URL) async throws -> [Double] {
        let asset = AVURLAsset(url: url)
        let dur = try await asset.load(.duration).seconds
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 400, height: 400)
        let image = try await gen.image(at: CMTime(seconds: dur / 2, preferredTimescale: 600)).image
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 2, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 2, height: 2))
        return px.map { Double($0) / 255 }   // bottom-left origin: [bottom-left, bottom-right, top-left, top-right]
    }

    @discardableResult
    func run(_ label: String, options: Options, name: String, codec: VideoCodec, percent: Double = 0.5, minFill: Double = 0.8, marker: Bool = false,
             expectedDisplay: (Int, Int)? = nil, inspect: ((CompressionResult) async throws -> Void)? = nil, file: StaticString = #filePath, line: UInt = #line) async throws -> CompressionResult {
        try await e2eRun(label, options: options, name: name, codec: codec, percent: percent, minFill: minFill, marker: marker, expectedDisplay: expectedDisplay, inspect: inspect, file: file, line: line)
    }

    func hd720(_ configure: (inout Options) -> Void = { _ in }) -> Options {
        var o = Options(); o.width = 1280; o.height = 720; o.seconds = 6; o.bitrate = 6_000_000
        configure(&o)
        return o
    }

    // MARK: Original four (1080p, 10 s)

    private func standard(_ label: String, codec: VideoCodec, target: @escaping (Int64) -> Double) async throws {
        let url = try await SyntheticVideo.cachedURL(name: "e2e-1080p")
        let info = try await VideoInfoLoader.load(url: url)
        let t = target(info.source.bytes)
        try await run(label, options: Options(), name: "e2e-1080p", codec: codec, percent: t)
    }

    func testFiftyPercentSmallerH264() async throws { try await standard("1080p-50pct", codec: .h264) { _ in 0.5 } }
    func testFiftyPercentSmallerHEVC() async throws { try await standard("1080p-50pct", codec: .hevc) { _ in 0.5 } }
    func testFixedMBTargetH264() async throws { try await standard("1080p-4MB", codec: .h264) { 4_000_000 / Double($0) } }
    func testFixedMBTargetHEVC() async throws { try await standard("1080p-2MB", codec: .hevc) { 2_000_000 / Double($0) } }

    // MARK: Sources that look like real phone video

    func testHLG10BitHEVC() async throws {
        guard SyntheticVideo.hlgSupported(width: 1280, height: 720) else { throw XCTSkip("HLG Main10 not writable here") }
        try await run("hlg-10bit", options: hd720 { $0.hlg = true }, name: "e2e-hlg", codec: .hevc, expectedDisplay: (1280, 720))
    }

    func testPortraitRotatedTrack() async throws {
        // Coded 1280x720 landscape, displayed 720x1280 through a 90 degree preferredTransform (how iPhones store portrait video).
        let o = hd720 { $0.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 720, ty: 0); $0.marker = true }
        let r = try await run("portrait-rotated", options: o, name: "e2e-portrait", codec: .hevc, marker: true, expectedDisplay: (720, 1280))
        XCTAssertLessThan(r.plan.width, r.plan.height)
    }

    func testNonSquarePixels() async throws {
        // Coded 960x720 with 4:3 pixels: displays as 1280x720.
        let o = hd720 { $0.width = 960; $0.height = 720; $0.pixelAspect = (4, 3); $0.marker = true }
        let r = try await run("non-square-pixels", options: o, name: "e2e-par", codec: .hevc, marker: true, expectedDisplay: (1280, 720))
        XCTAssertEqual(Double(r.plan.width) / Double(r.plan.height), 16.0 / 9.0, accuracy: 0.02)
    }

    func test60fps() async throws {
        let r = try await run("60fps", options: hd720 { $0.fps = 60; $0.bitrate = 8_000_000 }, name: "e2e-60fps", codec: .hevc)
        XCTAssertLessThanOrEqual(r.plan.fps, 60.01)
    }

    func testVideoShorterThanAudio() async throws {
        try await run("video-shorter-than-audio", options: hd720 { $0.seconds = 5; $0.audioSeconds = 8 }, name: "e2e-short-video", codec: .h264)
    }

    // MARK: Black frames

    func testFadeToBlackIsAllowed() async throws {
        try await run("fade-to-black", options: hd720 { $0.fadeToBlack = true }, name: "e2e-fade", codec: .h264, inspect: { r in
            let check = try XCTUnwrap(r.frameCheck)
            XCTAssertGreaterThanOrEqual(check.blackSourceFrames, 6, "the source really has black frames")
            XCTAssertTrue(check.passed)
            let outL = try await FrameCheck.lumas(of: r.url)
            let end = outL.map(\.pts).max() ?? 0
            let early = outL.filter { $0.pts < end - 1.1 }
            XCTAssertFalse(early.isEmpty)
            XCTAssertTrue(early.allSatisfy { $0.luma > FrameCheck.blackLuma }, "frames before the fade must not be black")
            XCTAssertGreaterThanOrEqual(check.blackOutputFrames, 6, "the fade's black frames are allowed to stay black")
        })
    }

    func testRejectsABlackFrame() async throws {
        let url = try await SyntheticVideo.cachedURL(name: "e2e-reject", options: hd720())
        let info = try await VideoInfoLoader.load(url: url)
        Compressor.debugFrameHook = { index, _, buffer in
            guard (30...33).contains(index) else { return }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), 0, CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
        }
        defer { Compressor.debugFrameHook = nil }
        do {
            let r = try await Compressor().compress(url: url, info: info.source, targetBytes: info.source.bytes / 2, codec: .h264, keepAudio: true) { _ in }
            try? FileManager.default.removeItem(at: r.url)
            XCTFail("a file with black frames was returned")
        } catch let e as StageError {
            guard case CompressorError.brokenOutput = e.underlying else { return XCTFail("unexpected error \(e)") }
            XCTAssertEqual(e.stage, .verify)
            print("E2E reject-black-frame: compressor threw brokenOutput as expected")
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(at: Compressor.workDirectory, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "mp4" } ?? []
        XCTAssertTrue(leftovers.isEmpty, "bad output files were deleted: \(leftovers)")
    }

    func testFallsBackWhenFirstPathIsBroken() async throws {
        Compressor.debugFrameHook = { index, path, buffer in
            guard path == 0, (30...33).contains(index) else { return }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), 0, CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
        }
        defer { Compressor.debugFrameHook = nil }
        let r = try await run("fallback-after-broken-path", options: hd720(), name: "e2e-reject", codec: .h264)
        XCTAssertEqual(r.decodePath, 1)
    }
}

extension XCTestCase {
    /// Runs one compression and applies every check. Returns the result for extra assertions.
    @discardableResult
    func e2eRun(_ label: String, options: SyntheticVideo.Options, name: String, codec: VideoCodec, percent: Double = 0.5, minFill: Double = 0.8, marker: Bool = false,
             expectedDisplay: (Int, Int)? = nil, inspect: ((CompressionResult) async throws -> Void)? = nil, file: StaticString = #filePath, line: UInt = #line) async throws -> CompressionResult {
        let url: URL
        do { url = try await SyntheticVideo.cachedURL(name: name, options: options) }
        catch { throw XCTSkip("Simulator can't encode this source: \(error.localizedDescription)") }
        let info = try await VideoInfoLoader.load(url: url)
        if let d = expectedDisplay {
            XCTAssertEqual(info.source.width, d.0, "source display width", file: file, line: line)
            XCTAssertEqual(info.source.height, d.1, "source display height", file: file, line: line)
        }
        let target = Int64(Double(info.source.bytes) * percent)
        let result: CompressionResult
        do {
            result = try await Compressor().compress(url: url, info: info.source, targetBytes: target, codec: codec, keepAudio: true) { _ in }
        } catch CompressorError.codecUnavailable(let c) {
            throw XCTSkip("\(c) unavailable")
        }
        defer { try? FileManager.default.removeItem(at: result.url) }

        // Size
        XCTAssertTrue(result.hitTarget, file: file, line: line)
        XCTAssertLessThanOrEqual(result.bytes, target, file: file, line: line)
        XCTAssertGreaterThanOrEqual(Double(result.bytes), Double(target) * minFill, file: file, line: line)

        // Structure: plays, aspect, durations aligned
        let asset = AVURLAsset(url: result.url)
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable, file: file, line: line)
        let video = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(video.count, 1, file: file, line: line)
        let (natural, transform, vRange) = try await video[0].load(.naturalSize, .preferredTransform, .timeRange)
        let shown = natural.applying(transform)
        XCTAssertEqual(abs(shown.width) / abs(shown.height), Double(info.source.width) / Double(info.source.height), accuracy: 0.02, "display aspect", file: file, line: line)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 1, file: file, line: line)
        let aRange = try await audio[0].load(.timeRange)
        let srcAsset = AVURLAsset(url: url)
        let srcV = try await srcAsset.loadTracks(withMediaType: .video)[0].load(.timeRange)
        XCTAssertEqual(vRange.duration.seconds, srcV.duration.seconds, accuracy: 0.15, "video duration", file: file, line: line)
        XCTAssertLessThanOrEqual(CMTimeRangeGetEnd(aRange).seconds, CMTimeRangeGetEnd(vRange).seconds + 0.1, "audio runs past video", file: file, line: line)

        // Per-frame check done inside the compressor...
        let inner = try XCTUnwrap(result.frameCheck, file: file, line: line)
        XCTAssertTrue(inner.passed, inner.summary, file: file, line: line)
        // ...and again, independently, by decoding both files.
        let srcL = try await FrameCheck.lumas(of: url)
        let outL = try await FrameCheck.lumas(of: result.url)
        let outer = FrameCheck.compare(reference: srcL, output: outL, tolerance: 0.5 / max(info.source.fps, 1), requireAllReferenceMatched: false)
        XCTAssertTrue(outer.failures.isEmpty, "independent check: \(outer.failures.prefix(3))", file: file, line: line)
        let meanSrc = srcL.map(\.luma).reduce(0, +) / Double(max(srcL.count, 1))
        let meanOut = outL.map(\.luma).reduce(0, +) / Double(max(outL.count, 1))
        XCTAssertEqual(meanOut, meanSrc, accuracy: max(0.03, meanSrc * 0.15), "mean luma", file: file, line: line)

        if marker {
            let a = try await EndToEndTests.quadrants(of: url), b = try await EndToEndTests.quadrants(of: result.url)
            for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: 0.12, "quadrant luma \(a) vs \(b)", file: file, line: line) }
        }

        print("E2E \(label) codec=\(codec.rawValue) target=\(target) actual=\(result.bytes) ratio=\(String(format: "%.3f", Double(result.bytes) / Double(target))) out=\(result.plan.width)x\(result.plan.height)@\(Int(result.plan.fps)) passes=\(result.passes) path=\(result.decodePath) lumaSrc=\(String(format: "%.3f", meanSrc)) lumaOut=\(String(format: "%.3f", meanOut)) frames=\(outL.count) check[\(inner.summary)] indep[\(outer.summary)]")
        try await inspect?(result)
        return result
    }

}
