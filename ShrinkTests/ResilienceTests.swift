import XCTest
import AVFoundation
@testable import Shrink

final class ResilienceTests: XCTestCase {
    typealias Options = SyntheticVideo.Options

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _paused = false
        var paused: Bool { get { lock.lock(); defer { lock.unlock() }; return _paused } set { lock.lock(); _paused = newValue; lock.unlock() } }
    }

    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private func hd720() -> Options {
        var o = Options(); o.width = 1280; o.height = 720; o.seconds = 6; o.bitrate = 6_000_000
        return o
    }

    override func tearDown() {
        Compressor.debugFrameHook = nil
        Compressor.debugPassFailure = nil
    }

    // MARK: Memory

    func testMemoryStaysFlatOnLongHDRClip() async throws {
        guard SyntheticVideo.hlgSupported(width: 1920, height: 1080) else { throw XCTSkip("HLG Main10 not writable here") }
        var o = Options(); o.width = 1920; o.height = 1080; o.seconds = 12; o.fps = 60; o.bitrate = 14_000_000; o.hlg = true
        let url = try await SyntheticVideo.cachedURL(name: "e2e-memory-hdr", options: o)
        let info = try await VideoInfoLoader.load(url: url)
        XCTAssertTrue(info.isHDR || info.bitDepth >= 10, "source should be 10-bit/HDR")

        let lock = NSLock()
        var samples: [(Int, UInt64)] = []
        Compressor.debugFrameHook = { index, _, _ in
            guard index % 100 == 0 else { return }
            let f = Self.footprint()
            lock.lock(); samples.append((index, f)); lock.unlock()
        }
        let result = try await Compressor().compress(url: url, info: info.source, targetBytes: info.source.bytes / 2, codec: .hevc, keepAudio: true) { _ in }
        defer { try? FileManager.default.removeItem(at: result.url) }
        lock.lock(); let all = samples; lock.unlock()

        let start = all.first?.1 ?? 0
        let baseline = all.first { $0.0 == 100 }?.1 ?? start
        let peak = all.map(\.1).max() ?? 0
        let mb = { (v: UInt64) in Double(v) / 1_048_576 }
        print("E2E memory samples=\(all.count) frames=\(info.source.fps * info.source.duration) start=\(String(format: "%.0f", mb(start))) MB baseline(frame100)=\(String(format: "%.0f", mb(baseline))) MB peak=\(String(format: "%.0f", mb(peak))) MB growth=\(String(format: "%.0f", mb(peak) - mb(baseline))) MB passes=\(result.passes) bytes=\(result.bytes)")
        XCTAssertGreaterThan(all.count, 2, "frames are dropped to 30 fps here, so 720 source frames give ~360 samples-eligible frames")
        XCTAssertLessThan(mb(peak) - mb(baseline), 150, "footprint must stay roughly flat while encoding")
        XCTAssertTrue(result.frameCheck?.passed ?? false)
    }

    // MARK: Background interruption

    func testBackgroundInterruptionRestartsThePass() async throws {
        let url = try await SyntheticVideo.cachedURL(name: "e2e-reject", options: hd720())
        let info = try await VideoInfoLoader.load(url: url)
        let c = Compressor()
        let flag = Box()
        var fired = false
        Compressor.debugFrameHook = { index, _, _ in
            guard index == 40, !fired else { return }
            fired = true
            c.interrupt()   // what the app does when the scene goes to the background
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { c.resume() }
        }
        let target = info.source.bytes / 2
        let r = try await c.compress(url: url, info: info.source, targetBytes: target, codec: .h264, keepAudio: true) { p in
            if p.paused { flag.paused = true }
        }
        defer { try? FileManager.default.removeItem(at: r.url) }
        print("E2E interruption: sawPaused=\(flag.paused) passes=\(r.passes) bytes=\(r.bytes) target=\(target) check[\(r.frameCheck?.summary ?? "-")]")
        XCTAssertTrue(flag.paused, "UI is told the pass is paused")
        XCTAssertEqual(r.passes, 1, "the restarted pass doesn't count as a size pass")
        XCTAssertLessThanOrEqual(r.bytes, target)
        XCTAssertTrue(r.frameCheck?.passed ?? false)
    }

    // MARK: Transient media-server errors

    func testTransientErrorRetriesOnce() async throws {
        let url = try await SyntheticVideo.cachedURL(name: "e2e-reject", options: hd720())
        let info = try await VideoInfoLoader.load(url: url)
        Compressor.debugAttempt = 0
        Compressor.debugPassFailure = { n in
            n == 1 ? NSError(domain: AVFoundationErrorDomain, code: -11819, userInfo: [NSLocalizedDescriptionKey: "Cannot Complete Action"]) : nil
        }
        let r = try await Compressor().compress(url: url, info: info.source, targetBytes: info.source.bytes / 2, codec: .h264, keepAudio: true) { _ in }
        defer { try? FileManager.default.removeItem(at: r.url) }
        print("E2E transient retry: attempts=\(Compressor.debugAttempt) passes=\(r.passes) bytes=\(r.bytes)")
        XCTAssertEqual(Compressor.debugAttempt, 2)
        XCTAssertEqual(r.passes, 1, "the retry isn't a size pass")
    }

    func testEncoderFailuresStepDownToSimplerPaths() async throws {
        let url = try await SyntheticVideo.cachedURL(name: "e2e-reject", options: hd720())
        let info = try await VideoInfoLoader.load(url: url)
        Compressor.debugAttempt = 0
        // Path 0 and path 1 each fail twice (one same-path retry, then a step down); path 2 must succeed.
        Compressor.debugPassFailure = { n in n <= 4 ? StageError(stage: .encode, underlying: NSError(domain: "Test", code: 9, userInfo: nil)) : nil }
        let r = try await Compressor().compress(url: url, info: info.source, targetBytes: info.source.bytes / 2, codec: .h264, keepAudio: true) { _ in }
        defer { try? FileManager.default.removeItem(at: r.url) }
        XCTAssertEqual(r.decodePath, 2)
        XCTAssertTrue(r.frameCheck?.passed ?? false)
        XCTAssertEqual(Compressor.debugAttempt, 5)
    }

    func testPersistentTransientErrorGivesUpAfterOneRetry() async throws {
        let url = try await SyntheticVideo.cachedURL(name: "e2e-reject", options: hd720())
        let info = try await VideoInfoLoader.load(url: url)
        Compressor.debugAttempt = 0
        Compressor.debugPassFailure = { _ in NSError(domain: AVFoundationErrorDomain, code: -11819, userInfo: nil) }
        do {
            _ = try await Compressor().compress(url: url, info: info.source, targetBytes: info.source.bytes / 2, codec: .h264, keepAudio: true) { _ in }
            XCTFail("should have thrown")
        } catch {
            XCTAssertEqual((error as NSError).code, -11819)
        }
        XCTAssertEqual(Compressor.debugAttempt, 2)
    }

    func testOtherErrorsAreNotRetried() async throws {
        let url = try await SyntheticVideo.cachedURL(name: "e2e-reject", options: hd720())
        let info = try await VideoInfoLoader.load(url: url)
        Compressor.debugAttempt = 0
        Compressor.debugPassFailure = { _ in NSError(domain: "Test", code: 7, userInfo: nil) }
        do {
            _ = try await Compressor().compress(url: url, info: info.source, targetBytes: info.source.bytes / 2, codec: .h264, keepAudio: true) { _ in }
            XCTFail("should have thrown")
        } catch {
            XCTAssertEqual((error as NSError).code, 7)
        }
        XCTAssertEqual(Compressor.debugAttempt, 1)
    }

    // MARK: Error details

    func testErrorReportCarriesTheWholeStory() async throws {
        let url = try await SyntheticVideo.cachedURL(name: "e2e-reject", options: hd720())
        let info = try await VideoInfoLoader.load(url: url)
        let inner = NSError(domain: NSOSStatusErrorDomain, code: -12785, userInfo: [NSLocalizedDescriptionKey: "VT died"])
        let outer = NSError(domain: AVFoundationErrorDomain, code: -11819, userInfo: [NSLocalizedDescriptionKey: "Cannot Complete Action", NSUnderlyingErrorKey: inner])
        let plan = BitratePlanner.plan(source: info.source, targetBytes: 2_000_000, codec: .hevc, keepAudio: true).plan
        let report = ErrorReport(stage: .encode, error: StageError(stage: .encode, underlying: outer), video: info, plan: plan, codec: .hevc, targetBytes: 2_000_000, keepAudio: true)
        let d = report.details
        print("E2E error details:\n\(d)")
        for needle in ["Stage: encode", "AVFoundationErrorDomain -11819", "Cannot Complete Action", "NSOSStatusErrorDomain -12785", "1280x720", "H.264", "HDR no", "HEVC", "target"] {
            XCTAssertTrue(d.contains(needle), "details should contain \(needle)")
        }
        XCTAssertTrue(report.summary.contains("-11819"))
        XCTAssertTrue(Compressor.isTransient(StageError(stage: .encode, underlying: outer)))
    }
}
