import XCTest
@testable import Shrink

final class BitratePlannerTests: XCTestCase {
    func src(bytes: Int64 = 100_000_000, duration: Double = 60, w: Int = 1920, h: Int = 1080, fps: Double = 30, audio: Bool = true) -> SourceInfo {
        SourceInfo(bytes: bytes, duration: duration, width: w, height: h, fps: fps, hasAudio: audio)
    }

    func testKeepsSourceSizeWhenBudgetIsRich() {
        let o = BitratePlanner.plan(source: src(), targetBytes: 60_000_000, codec: .hevc, keepAudio: true)
        XCTAssertTrue(o.isFeasible)
        XCTAssertEqual(o.plan.width, 1920); XCTAssertEqual(o.plan.height, 1080)
        XCTAssertEqual(o.plan.audioBitrate, 128_000)
    }

    func testStepsDownResolution() {
        // ~1.3 Mbps for a 1080p30 source: below 0.06 bpp at 1080p, fine at 540p.
        let target: Int64 = 10_000_000
        let o = BitratePlanner.plan(source: src(), targetBytes: target, codec: .hevc, keepAudio: true)
        XCTAssertTrue(o.isFeasible)
        XCTAssertLessThan(o.plan.height, 1080)
        XCTAssertTrue(BitratePlanner.resolutionLadder.contains(o.plan.height))
        let bpp = Double(o.plan.videoBitrate) / Double(o.plan.width * o.plan.height) / o.plan.fps
        XCTAssertGreaterThanOrEqual(bpp, VideoCodec.hevc.keepSizeBitsPerPixel)
    }

    func testH264NeedsMoreBitsPerPixelThanHEVC() {
        let t: Int64 = 25_000_000
        let hevc = BitratePlanner.plan(source: src(), targetBytes: t, codec: .hevc, keepAudio: true).plan
        let h264 = BitratePlanner.plan(source: src(), targetBytes: t, codec: .h264, keepAudio: true).plan
        XCTAssertGreaterThanOrEqual(hevc.height, h264.height)
    }

    func testAudioTiers() {
        func audio(_ target: Int64) -> Int { BitratePlanner.plan(source: src(duration: 100), targetBytes: target, codec: .hevc, keepAudio: true).plan.audioBitrate }
        XCTAssertEqual(audio(30_000_000), 128_000)   // 2.4 Mbps
        XCTAssertEqual(audio(8_000_000), 96_000)     // ~630 kbps
        XCTAssertEqual(audio(4_500_000), 64_000)     // ~350 kbps
        XCTAssertEqual(audio(3_000_000), 48_000)     // ~235 kbps
    }

    func testNoAudioWhenDroppedOrAbsent() {
        XCTAssertEqual(BitratePlanner.plan(source: src(), targetBytes: 30_000_000, codec: .hevc, keepAudio: false).plan.audioBitrate, 0)
        XCTAssertEqual(BitratePlanner.plan(source: src(audio: false), targetBytes: 30_000_000, codec: .hevc, keepAudio: true).plan.audioBitrate, 0)
    }

    func testOverheadIsReserved() {
        let target: Int64 = 20_000_000
        let o = BitratePlanner.plan(source: src(), targetBytes: target, codec: .hevc, keepAudio: true)
        let est = o.plan.estimatedBytes(duration: 60)
        XCTAssertLessThanOrEqual(est, target + 1000)
        let raw = Double(o.plan.videoBitrate + o.plan.audioBitrate) * 60 / 8
        XCTAssertEqual(raw / Double(target), 0.98, accuracy: 0.005)
    }

    func testImpossibleTargetReportsMinimum() {
        let o = BitratePlanner.plan(source: src(), targetBytes: 100_000, codec: .hevc, keepAudio: true)
        XCTAssertFalse(o.isFeasible)
        XCTAssertGreaterThan(o.minimumBytes, 100_000)
        XCTAssertEqual(o.plan.height, 360)
        // The minimum itself is feasible.
        let at = BitratePlanner.plan(source: src(), targetBytes: o.minimumBytes, codec: .hevc, keepAudio: true)
        XCTAssertTrue(at.isFeasible)
        XCTAssertEqual(at.plan.height, 360)
        XCTAssertFalse(BitratePlanner.plan(source: src(), targetBytes: o.minimumBytes - 5000, codec: .hevc, keepAudio: true).isFeasible)
    }

    func testFeasiblePlansNeverDropBelowFloor() {
        for codec in VideoCodec.allCases {
            let min = BitratePlanner.plan(source: src(), targetBytes: 1, codec: codec, keepAudio: true).minimumBytes
            for extra in stride(from: 0, to: 400_000, by: 7_000) {
                let o = BitratePlanner.plan(source: src(), targetBytes: min + Int64(extra), codec: codec, keepAudio: true)
                XCTAssertTrue(o.isFeasible)
                let bpp = Double(o.plan.videoBitrate) / Double(o.plan.width * o.plan.height) / o.plan.fps
                XCTAssertGreaterThanOrEqual(bpp + 0.0005, codec.floorBitsPerPixel)
                XCTAssertLessThanOrEqual(o.plan.estimatedBytes(duration: 60), min + Int64(extra) + 2000)
            }
        }
    }

    func testNeverUpscales() {
        let small = src(w: 640, h: 360)
        let o = BitratePlanner.plan(source: small, targetBytes: 90_000_000, codec: .hevc, keepAudio: true)
        XCTAssertEqual(o.plan.width, 640); XCTAssertEqual(o.plan.height, 360)
        let tiny = BitratePlanner.plan(source: src(w: 320, h: 240), targetBytes: 1_000_000, codec: .hevc, keepAudio: true)
        XCTAssertLessThanOrEqual(tiny.plan.width, 320); XCTAssertLessThanOrEqual(tiny.plan.height, 240)
    }

    func testEvenDimensionsAndAspect() {
        for (w, h) in [(1920, 1080), (1080, 1920), (1280, 720), (1000, 563), (3840, 2160), (1919, 1079), (1440, 1080)] {
            for size in BitratePlanner.candidateSizes(width: w, height: h) {
                XCTAssertEqual(size.w % 2, 0); XCTAssertEqual(size.h % 2, 0)
                XCTAssertEqual(Double(size.w) / Double(size.h), Double(w) / Double(h), accuracy: 0.02)
                XCTAssertLessThanOrEqual(size.w, w); XCTAssertLessThanOrEqual(size.h, h)
            }
        }
    }

    func testPortraitUsesShortSide() {
        let sizes = BitratePlanner.candidateSizes(width: 1080, height: 1920)
        XCTAssertEqual(sizes[1].w, 720); XCTAssertEqual(sizes[1].h, 1280)
    }

    func testFpsCapOnlyWhenTight() {
        let s = src(fps: 60)
        let rich = BitratePlanner.plan(source: s, targetBytes: 90_000_000, codec: .hevc, keepAudio: true).plan
        XCTAssertEqual(rich.fps, 60)
        let tight = BitratePlanner.plan(source: s, targetBytes: 8_000_000, codec: .hevc, keepAudio: true).plan
        XCTAssertEqual(tight.fps, 30)
    }

    func testLadderOrder() {
        let sizes = BitratePlanner.candidateSizes(width: 3840, height: 2160).map(\.h)
        XCTAssertEqual(sizes, [2160, 1440, 1080, 720, 540, 480, 360])
    }
}
