import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import VideoToolbox
import os

struct CompressionProgress: Equatable, Sendable {
    var fraction: Double
    var pass: Int
    var maxPasses: Int
    var remaining: TimeInterval?
    /// True while the app is in the background and the encode is waiting to restart.
    var paused = false
}

struct CompressionResult: Sendable {
    var url: URL
    var bytes: Int64
    var targetBytes: Int64
    var plan: EncodePlan
    var passes: Int
    var hitTarget: Bool
    var frameCheck: FrameCheckReport?
    /// 0 = native path, 1 = Core Image default-colour fallback, 2 = minimal path (bilinear scale, bare encoder settings).
    var decodePath: Int = 0
}

enum CompressorError: LocalizedError {
    case noVideoTrack
    case codecUnavailable(String)
    case brokenOutput
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "That file doesn't contain a video track."
        case .codecUnavailable(let c): return "\(c) encoding isn't available on this device."
        case .brokenOutput: return "Shrink couldn't read the frames of this video."
        case .failed(let m): return m
        }
    }
}

enum Stage: String, Sendable { case load, plan, read, render, encode, verify, save }

/// An error tagged with the stage it came from.
struct StageError: LocalizedError {
    var stage: Stage
    var underlying: Error
    var errorDescription: String? { underlying.localizedDescription }
}

struct PassInterrupted: Error {}
final class FractionBox: @unchecked Sendable { var value = 0.0 }

/// Lets the app stop the running pass when it goes to the background (hardware encoding isn't allowed there)
/// and restart it when the app is active again.
final class PassControl: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    fileprivate var current: EncodeSession?

    var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return paused }

    func interrupt() {
        lock.lock(); paused = true; let s = current; lock.unlock()
        s?.cancel(interrupted: true)
    }

    func resume() {
        lock.lock(); paused = false; let w = waiters; waiters = []; lock.unlock()
        w.forEach { $0.resume() }
    }

    func waitUntilActive() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if paused { waiters.append(c); lock.unlock() } else { lock.unlock(); c.resume() }
        }
    }

    fileprivate func register(_ s: EncodeSession?) {
        lock.lock(); current = s; let p = paused; lock.unlock()
        if p { s?.cancel(interrupted: true) }
    }
}

final class Compressor {
    static let maxPasses = 3
    /// Highest fallback path; each failed path moves to the next, simpler one before giving up.
    static let lastPath = 2
    let control = PassControl()
    func interrupt() { control.interrupt() }
    func resume() { control.resume() }
    private static let log = Logger(subsystem: "com.kiddreads.shrink", category: "compress")

    #if DEBUG
    /// Test hook: return an error to make the next pass fail before it starts (argument: pass attempt counter).
    nonisolated(unsafe) static var debugPassFailure: ((Int) -> Error?)?
    nonisolated(unsafe) static var debugAttempt = 0
    /// Test hook: called with (frame index, decode path, output buffer) just before each frame is written.
    nonisolated(unsafe) static var debugFrameHook: ((Int, Int, CVPixelBuffer) -> Void)?
    #endif

    static var workDirectory: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Shrink", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Encodes, verifies every frame, checks the real file size, and re-encodes with a corrected bitrate until the result
    /// lands at or under the target. A file that fails the per-frame check is never returned.
    func compress(url: URL, info: SourceInfo, targetBytes: Int64, codec: VideoCodec, keepAudio: Bool,
                  progress: @escaping @Sendable (CompressionProgress) -> Void) async throws -> CompressionResult {
        var plan = BitratePlanner.plan(source: info, targetBytes: targetBytes, codec: codec, keepAudio: keepAudio).plan
        var best: (url: URL, bytes: Int64, plan: EncodePlan, report: FrameCheckReport)?
        var smallestOver: (url: URL, bytes: Int64, plan: EncodePlan, report: FrameCheckReport)?
        var passes = 0
        var path = 0

        func discard(_ u: URL) { try? FileManager.default.removeItem(at: u) }
        func cleanup() { if let best { discard(best.url) }; if let smallestOver { discard(smallestOver.url) } }

        let lastFraction = FractionBox()
        for pass in 1...Self.maxPasses {
            try Task.checkCancellation()
            passes = pass
            var verified: (url: URL, report: FrameCheckReport)?
            var transientRetries = 0
            attempts: while path <= Self.lastPath {
                await control.waitUntilActive()
                try Task.checkCancellation()
                let out = Self.workDirectory.appendingPathComponent("shrink-\(UUID().uuidString).mp4")
                do {
                    #if DEBUG
                    Self.debugAttempt += 1
                    if let err = Self.debugPassFailure?(Self.debugAttempt) { throw err }
                    #endif
                    let frames = try await encodePass(url: url, plan: plan, codec: codec, output: out, path: path) { f, remaining in
                        lastFraction.value = f
                        progress(CompressionProgress(fraction: f, pass: pass, maxPasses: Self.maxPasses, remaining: remaining))
                    }
                    let outLumas: [FrameLuma]
                    do { outLumas = try await FrameCheck.lumas(of: out) } catch { throw StageError(stage: .verify, underlying: error) }
                    let report = FrameCheck.compare(reference: frames, output: outLumas, tolerance: 0.25 / max(plan.fps, 1))
                    if report.passed {
                        verified = (out, report)
                        break attempts
                    }
                    Self.log.error("frame check failed on path \(path): \(report.summary) \(report.failures.prefix(3).joined(separator: "; "))")
                    discard(out)
                    path += 1
                } catch is PassInterrupted {
                    discard(out)
                    progress(CompressionProgress(fraction: lastFraction.value, pass: pass, maxPasses: Self.maxPasses, remaining: nil, paused: true))
                    continue attempts   // waits at the top until the app is active again; not a size pass
                } catch {
                    discard(out)
                    if control.isPaused && !(error is CancellationError) { continue attempts }
                    if !(error is CancellationError), transientRetries < 1, Self.isTransient(error) {
                        transientRetries += 1
                        Self.log.error("transient media error, retrying the pass: \(String(describing: error))")
                        try await Task.sleep(nanoseconds: 1_500_000_000)
                        continue attempts   // fresh reader, writer and CIContext; not a size pass
                    }
                    // A hardware or Core Image failure on one path is recoverable on a simpler one: step down instead of failing.
                    if !(error is CancellationError), path < Self.lastPath, Self.canFallBack(error) {
                        Self.log.error("path \(path) failed (\(String(describing: error))); falling back to path \(path + 1)")
                        transientRetries = 0
                        path += 1
                        continue attempts
                    }
                    cleanup()
                    throw error
                }
            }
            guard let verified else { cleanup(); throw StageError(stage: .verify, underlying: CompressorError.brokenOutput) }

            let size = (try? verified.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            Self.log.info("pass \(pass): \(size) bytes vs target \(targetBytes), video \(plan.videoBitrate) bps, \(verified.report.summary)")

            if size <= targetBytes {
                if let b = best, b.bytes >= size { discard(verified.url) } else { if let b = best { discard(b.url) }; best = (verified.url, size, plan, verified.report) }
            } else {
                if let s = smallestOver, s.bytes <= size { discard(verified.url) } else { if let s = smallestOver { discard(s.url) }; smallestOver = (verified.url, size, plan, verified.report) }
            }

            let ratio = Double(size) / Double(targetBytes)
            if size <= targetBytes && ratio >= 0.85 { break }
            if pass == Self.maxPasses { break }
            let factor = size > targetBytes
                ? Double(targetBytes) / Double(size) * 0.97
                : min(Double(targetBytes) / Double(max(size, 1)) * 0.98, 3)
            plan.videoBitrate = max(BitratePlanner.minimumVideoBitrate, Int(Double(plan.videoBitrate) * factor))
        }

        if let best {
            if let s = smallestOver { discard(s.url) }
            if Double(best.bytes) < Double(targetBytes) * 0.85 {
                Self.log.notice("finished \(best.bytes) bytes, more than 15% under target \(targetBytes)")
            }
            return CompressionResult(url: best.url, bytes: best.bytes, targetBytes: targetBytes, plan: best.plan, passes: passes,
                                     hitTarget: true, frameCheck: best.report, decodePath: path)
        }
        guard let over = smallestOver else { throw CompressorError.failed("Encoding produced no output.") }
        Self.log.error("missed target: \(over.bytes) > \(targetBytes)")
        return CompressionResult(url: over.url, bytes: over.bytes, targetBytes: targetBytes, plan: over.plan, passes: passes,
                                 hitTarget: false, frameCheck: over.report, decodePath: path)
    }

    static func underlyingChain(_ error: Error) -> [NSError] {
        var chain: [NSError] = []
        var e: NSError? = error as NSError
        while let cur = e, chain.count < 8 {
            chain.append(cur)
            e = cur.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return chain
    }

    /// Failures worth trying a simpler configuration for: encoder/reader errors and unsupported settings.
    static func canFallBack(_ error: Error) -> Bool {
        if let st = error as? StageError { return st.stage == .encode || st.stage == .read }
        if let ce = error as? CompressorError, case .codecUnavailable = ce { return true }
        return false
    }

    /// Media-server hiccups worth one retry: services reset, interrupted, a writer/reader failure, or -11800 caused by a system error.
    static func isTransient(_ error: Error) -> Bool {
        if let st = error as? StageError, st.stage == .encode || st.stage == .read { return true }
        let chain = underlyingChain((error as? StageError)?.underlying ?? error)
        for ns in chain where ns.domain == AVFoundationErrorDomain {
            if ns.code == -11819 || ns.code == -11847 { return true }
            if ns.code == -11800 && chain.contains(where: { $0.domain == NSOSStatusErrorDomain || $0.domain == NSPOSIXErrorDomain }) { return true }
        }
        return false
    }

    private func encodePass(url: URL, plan: EncodePlan, codec: VideoCodec, output: URL, path: Int,
                            progress: @escaping @Sendable (Double, TimeInterval?) -> Void) async throws -> [FrameLuma] {
        let session: EncodeSession
        do { session = try await EncodeSession(url: url, plan: plan, codec: codec, output: output, path: path) }
        catch let e as CompressorError { throw e }
        catch { throw StageError(stage: .encode, underlying: error) }
        control.register(session)
        defer { control.register(nil) }
        try await withTaskCancellationHandler {
            try await session.run(progress: progress)
        } onCancel: {
            session.cancel(interrupted: false)
        }
        return session.sourceFrames
    }
}

/// Orientation, pixel aspect, scaling and HDR to SDR conversion for one frame, done with Core Image.
private final class FrameRenderer {
    let context: CIContext
    let orientation: CGImagePropertyOrientation
    let pixelAspect: Double
    let width: Int, height: Int
    let hdr: Bool
    let path: Int
    let space709 = CGColorSpace(name: CGColorSpace.itur_709)!

    init(transform: CGAffineTransform, pixelAspect: Double, width: Int, height: Int, hdr: Bool, path: Int) {
        orientation = Self.orientation(for: transform)
        self.pixelAspect = pixelAspect
        self.width = width; self.height = height; self.hdr = hdr; self.path = path
        if path == 0 {
            context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .cacheIntermediates: false, .useSoftwareRenderer: false])
        } else {
            context = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: false])
        }
    }

    static func orientation(for t: CGAffineTransform) -> CGImagePropertyOrientation {
        let a = Int(t.a.rounded()), b = Int(t.b.rounded()), c = Int(t.c.rounded()), d = Int(t.d.rounded())
        switch (a, b, c, d) {
        case (0, 1, -1, 0): return .right
        case (0, -1, 1, 0): return .left
        case (-1, 0, 0, -1): return .down
        case (-1, 0, 0, 1): return .upMirrored
        case (1, 0, 0, -1): return .downMirrored
        case (0, 1, 1, 0): return .leftMirrored
        case (0, -1, -1, 0): return .rightMirrored
        default: return .up
        }
    }

    func render(_ source: CVPixelBuffer, into out: CVPixelBuffer) {
        var image = CIImage(cvPixelBuffer: source)
        if abs(pixelAspect - 1) > 0.001 { image = image.transformed(by: CGAffineTransform(scaleX: pixelAspect, y: 1)) }
        image = image.oriented(orientation)
        if hdr, #available(iOS 18.0, *) {
            let f = CIFilter.toneMapHeadroom()
            f.inputImage = image
            f.sourceHeadroom = image.contentHeadroom > 1 ? image.contentHeadroom : 4
            f.targetHeadroom = 1
            if let mapped = f.outputImage { image = mapped }
        }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let sx = Double(width) / image.extent.width, sy = Double(height) / image.extent.height
        if abs(sx - 1) > 0.001 || abs(sy - 1) > 0.001 {
            if path >= 2 {
                image = image.samplingLinear().transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            } else {
                let f = CIFilter.lanczosScaleTransform()
                f.inputImage = image
                f.scale = Float(sy)
                f.aspectRatio = Float(sx / sy)
                if let scaled = f.outputImage { image = scaled }
            }
        }
        image = image.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        context.render(image, to: out, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: space709)
        CVBufferSetAttachment(out, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(out, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(out, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }
}

/// One AVAssetReader -> Core Image -> AVAssetWriter pass.
private final class EncodeSession: @unchecked Sendable {
    let reader: AVAssetReader
    let writer: AVAssetWriter
    let videoOut: AVAssetReaderTrackOutput
    let videoIn: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let renderer: FrameRenderer
    var audioOut: AVAssetReaderTrackOutput?
    var audioIn: AVAssetWriterInput?
    let range: CMTimeRange
    let fps: Double
    let path: Int
    private let lock = NSLock()
    private var cancelled = false
    private var interrupted = false
    private var frames: [FrameLuma] = []
    var sourceFrames: [FrameLuma] { lock.lock(); defer { lock.unlock() }; return frames }

    init(url: URL, plan: EncodePlan, codec: VideoCodec, output: URL, path: Int) async throws {
        self.path = path
        fps = plan.fps
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CompressorError.noVideoTrack }
        let (transform, trackRange, formats, characteristics) = try await track.load(.preferredTransform, .timeRange, .formatDescriptions, .mediaCharacteristics)
        range = trackRange

        var bits = 8
        var par = 1.0
        if let fd = formats.first {
            if let n = (CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? NSNumber)?.intValue { bits = n }
            par = VideoInfoLoader.pixelAspect(fd)
        }
        let hdr = characteristics.contains(.containsHDRVideo)
        let tenBit = hdr || bits >= 10

        reader = try AVAssetReader(asset: asset)
        reader.timeRange = trackRange   // audio is cut at the last video frame
        try? FileManager.default.removeItem(at: output)
        writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        renderer = FrameRenderer(transform: transform, pixelAspect: par, width: plan.width, height: plan.height, hdr: hdr, path: path)

        let readFormat: OSType = path == 0
            ? (tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            : (path == 1 && tenBit ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_32BGRA)
        videoOut = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: readFormat])
        videoOut.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOut) else { throw CompressorError.failed("Couldn't read the video track.") }
        reader.add(videoOut)

        var props: [String: Any] = [AVVideoAverageBitRateKey: plan.videoBitrate]
        if path < 2 {
            props[AVVideoMaxKeyFrameIntervalKey] = Int((plan.fps * 2).rounded())
            props[AVVideoMaxKeyFrameIntervalDurationKey] = 2.0
            props[AVVideoExpectedSourceFrameRateKey] = plan.fps
            props[AVVideoAllowFrameReorderingKey] = true
            props[AVVideoProfileLevelKey] = codec == .h264 ? AVVideoProfileLevelH264HighAutoLevel : (kVTProfileLevel_HEVC_Main_AutoLevel as String)
        } else {
            // Minimal path: only the bitrate, a keyframe interval, no reordering; the encoder picks the profile.
            props[AVVideoMaxKeyFrameIntervalKey] = max(Int((plan.fps * 2).rounded()), 1)
            props[AVVideoAllowFrameReorderingKey] = false
        }
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: plan.width,
            AVVideoHeightKey: plan.height,
            AVVideoCompressionPropertiesKey: props,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw CompressorError.codecUnavailable(codec.label)
        }
        videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoIn.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: plan.width,
            kCVPixelBufferHeightKey as String: plan.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        guard writer.canAdd(videoIn) else { throw CompressorError.failed("Couldn't set up the video encoder.") }
        writer.add(videoIn)

        if plan.audioBitrate > 0, let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
            let channels = plan.audioBitrate <= 48_000 ? 1 : 2
            let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: channels,
            ])
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: plan.audioBitrate,
            ])
            aIn.expectsMediaDataInRealTime = false
            if reader.canAdd(out), writer.canAdd(aIn) {
                reader.add(out); writer.add(aIn)
                audioOut = out; audioIn = aIn
            }
        }
    }

    func cancel(interrupted: Bool) {
        lock.lock(); cancelled = true; if interrupted { self.interrupted = true }; lock.unlock()
        reader.cancelReading()
    }
    private var wasInterrupted: Bool { lock.lock(); defer { lock.unlock() }; return interrupted }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func run(progress: @escaping @Sendable (Double, TimeInterval?) -> Void) async throws {
        guard reader.startReading() else { throw StageError(stage: .read, underlying: reader.error ?? CompressorError.failed("Couldn't read the video.")) }
        guard writer.startWriting() else { throw StageError(stage: .encode, underlying: writer.error ?? CompressorError.failed("Couldn't start writing.")) }
        writer.startSession(atSourceTime: range.start)

        let started = Date()
        let start = range.start.seconds
        let duration = max(range.duration.seconds, 0.001)
        let interval = 1 / max(fps, 1)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let group = DispatchGroup()
            var failure: Error?

            // Video: decode, render with Core Image, write with the source PTS. Frames are dropped to reach the planned fps.
            group.enter()
            let vq = DispatchQueue(label: "shrink.video")
            var vdone = false
            var nextEmit = -Double.infinity
            var index = 0
            enum Step { case proceed, done, failed }
            videoIn.requestMediaDataWhenReady(on: vq) { [self] in
                while videoIn.isReadyForMoreMediaData && !vdone {
                    // One pool per frame: decoded buffers, CIImages and IOSurfaces are released every iteration.
                    let step: Step = autoreleasepool {
                        if isCancelled { return .done }
                        guard let sample = videoOut.copyNextSampleBuffer() else { return .done }
                        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                        let t = pts.seconds
                        if nextEmit == -Double.infinity { nextEmit = t }
                        if t + 0.25 * interval < nextEmit { return .proceed }
                        nextEmit += interval
                        if nextEmit < t { nextEmit = t + interval }
                        guard let src = CMSampleBufferGetImageBuffer(sample), let pool = adaptor.pixelBufferPool else { return .proceed }
                        var outBuffer: CVPixelBuffer?
                        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer)
                        guard let dst = outBuffer else { return .proceed }
                        renderer.render(src, into: dst)
                        #if DEBUG
                        Compressor.debugFrameHook?(index, path, dst)
                        #endif
                        index += 1
                        let luma = FrameCheck.meanLuma(src)
                        lock.lock(); frames.append(FrameLuma(pts: t, luma: luma)); lock.unlock()
                        let f = min(max((t - start) / duration, 0), 1)
                        let elapsed = Date().timeIntervalSince(started)
                        progress(f, f > 0.03 ? elapsed / f * (1 - f) : nil)
                        if !adaptor.append(dst, withPresentationTime: pts) {
                            failure = writer.error ?? CompressorError.failed("Writing failed.")
                            return .failed
                        }
                        return .proceed
                    }
                    if step != .proceed { vdone = true; videoIn.markAsFinished(); group.leave(); return }
                }
            }

            if let audioIn, let audioOut {
                group.enter()
                let aq = DispatchQueue(label: "shrink.audio")
                var adone = false
                audioIn.requestMediaDataWhenReady(on: aq) { [self] in
                    while audioIn.isReadyForMoreMediaData && !adone {
                        let more: Bool = autoreleasepool {
                            if isCancelled { return false }
                            guard let sample = audioOut.copyNextSampleBuffer() else { return false }
                            return audioIn.append(sample)
                        }
                        if !more { adone = true; audioIn.markAsFinished(); group.leave(); return }
                    }
                }
            }

            group.notify(queue: .global()) { [self] in
                if isCancelled {
                    writer.cancelWriting()
                    cont.resume(throwing: wasInterrupted ? PassInterrupted() : CancellationError())
                } else if reader.status == .failed {
                    writer.cancelWriting()
                    cont.resume(throwing: StageError(stage: .read, underlying: reader.error ?? CompressorError.failed("Reading failed.")))
                } else if writer.status == .failed || failure != nil {
                    cont.resume(throwing: StageError(stage: .encode, underlying: (failure ?? writer.error) ?? CompressorError.failed("Writing failed.")))
                } else {
                    writer.endSession(atSourceTime: CMTimeAdd(range.start, range.duration))
                    writer.finishWriting { [self] in
                        if writer.status == .completed { cont.resume() }
                        else { cont.resume(throwing: StageError(stage: .encode, underlying: writer.error ?? CompressorError.failed("Writing failed."))) }
                    }
                }
            }
        }
    }
}
