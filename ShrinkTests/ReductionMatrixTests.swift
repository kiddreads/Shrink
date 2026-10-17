import XCTest
import AVFoundation
@testable import Shrink

/// Phone-like sources compressed at every reduction a user can pick. A reported failure: anything above ~20% reduction failed on a real phone.
final class ReductionMatrixTests: XCTestCase {
    typealias Options = SyntheticVideo.Options
    static let reductions = [10, 30, 50, 70, 85, 90]

    private func landscape1440(hdr: Bool) -> Options {
        var o = Options(); o.width = 1440; o.height = 1080; o.seconds = 3; o.fps = 60; o.bitrate = 8_000_000
        o.audioChannels = 2; o.audioRate = 48000; o.hlg = hdr
        return o
    }
    private func portrait1080() -> Options {
        // Coded 1920x1080 landscape, displayed 1080x1920 through a 90 degree preferredTransform.
        var o = Options(); o.width = 1920; o.height = 1080; o.seconds = 3; o.fps = 60; o.bitrate = 10_000_000
        o.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0); o.marker = true
        o.audioChannels = 2; o.audioRate = 48000
        return o
    }
    private func uhd() -> Options {
        var o = Options(); o.width = 3840; o.height = 2160; o.seconds = 2; o.fps = 30; o.bitrate = 25_000_000
        o.audioChannels = 2; o.audioRate = 48000
        return o
    }
    private func nonSquare60() -> Options {
        // Coded 1080x1080 with 4:3 pixels: displays as 1440x1080.
        var o = Options(); o.width = 1080; o.height = 1080; o.seconds = 3; o.fps = 60; o.bitrate = 8_000_000
        o.pixelAspect = (4, 3); o.audioChannels = 2; o.audioRate = 48000
        return o
    }

    /// Runs every reduction and reports each failure separately so one run shows the whole picture.
    private func matrix(_ name: String, options: Options, codec: VideoCodec, display: (Int, Int), marker: Bool = false) async throws {
        let cacheName = "mx-\(name)"
        let url: URL
        do { url = try await SyntheticVideo.cachedURL(name: cacheName, options: options) }
        catch { throw XCTSkip("Simulator can't encode this source: \(error.localizedDescription)") }
        let info = try await VideoInfoLoader.load(url: url)
        XCTAssertEqual(info.source.width, display.0, "\(name) display width")
        XCTAssertEqual(info.source.height, display.1, "\(name) display height")
        var failed: [String] = []
        for pct in Self.reductions {
            let target = Int64(Double(info.source.bytes) * (1 - Double(pct) / 100))
            let outcome = BitratePlanner.plan(source: info.source, targetBytes: target, codec: codec, keepAudio: true)
            guard outcome.isFeasible else {
                print("E2E-MX \(name) \(codec.rawValue) \(pct)% -> tooSmall (min \(outcome.minimumBytes) > \(target)), refused up front")
                continue
            }
            do {
                try await e2eRun("\(name)-\(pct)pct", options: options, name: cacheName, codec: codec, percent: 1 - Double(pct) / 100, minFill: 0.5,
                                  marker: marker, expectedDisplay: display, inspect: { r in
                    let asset = AVURLAsset(url: r.url)
                    let t = try await asset.loadTracks(withMediaType: .video)[0]
                    let (size, transform, fps) = try await t.load(.naturalSize, .preferredTransform, .nominalFrameRate)
                    let shown = size.applying(transform)
                    XCTAssertEqual(Int(abs(shown.width)), r.plan.width, "\(name) \(pct)% output width")
                    XCTAssertEqual(Int(abs(shown.height)), r.plan.height, "\(name) \(pct)% output height")
                    XCTAssertEqual(Double(fps), r.plan.fps, accuracy: 3, "\(name) \(pct)% output fps")
                })
            } catch {
                failed.append("\(pct)%: \(error)")
                XCTFail("\(name) \(codec.rawValue) \(pct)% failed: \(error) | \(ErrorReport(stage: ((error as? StageError)?.stage ?? .encode), error: error).details)")
            }
        }
        XCTAssertTrue(failed.isEmpty, "\(name) \(codec.rawValue) failed at: \(failed)")
    }

    func testLandscape1440HEVC() async throws { try await matrix("l1440-hevc", options: landscape1440(hdr: false), codec: .hevc, display: (1440, 1080)) }
    func testLandscape1440H264() async throws { try await matrix("l1440-h264", options: landscape1440(hdr: false), codec: .h264, display: (1440, 1080)) }
    func testLandscape1440HDRHEVC() async throws {
        guard SyntheticVideo.hlgSupported(width: 1440, height: 1080) else { throw XCTSkip("HLG Main10 not writable here") }
        try await matrix("l1440hdr-hevc", options: landscape1440(hdr: true), codec: .hevc, display: (1440, 1080))
    }
    func testLandscape1440HDRH264() async throws {
        guard SyntheticVideo.hlgSupported(width: 1440, height: 1080) else { throw XCTSkip("HLG Main10 not writable here") }
        try await matrix("l1440hdr-h264", options: landscape1440(hdr: true), codec: .h264, display: (1440, 1080))
    }
    func testPortrait1080HEVC() async throws { try await matrix("p1080-hevc", options: portrait1080(), codec: .hevc, display: (1080, 1920), marker: true) }
    func testPortrait1080H264() async throws { try await matrix("p1080-h264", options: portrait1080(), codec: .h264, display: (1080, 1920), marker: true) }
    func testUHDHEVC() async throws { try await matrix("uhd-hevc", options: uhd(), codec: .hevc, display: (3840, 2160)) }
    func testUHDH264() async throws { try await matrix("uhd-h264", options: uhd(), codec: .h264, display: (3840, 2160)) }
    func testNonSquare60HEVC() async throws { try await matrix("par60-hevc", options: nonSquare60(), codec: .hevc, display: (1440, 1080)) }
    func testNonSquare60H264() async throws { try await matrix("par60-h264", options: nonSquare60(), codec: .h264, display: (1440, 1080)) }
}
