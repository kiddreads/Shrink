#if DEBUG
import AVFoundation
import CoreGraphics
import VideoToolbox

/// Generates test clips with moving, detailed content (used by the unit tests and the screenshot scenes).
enum SyntheticVideo {
    struct Options {
        var width = 1920
        var height = 1080
        var seconds = 10.0
        var fps = 30
        var bitrate = 12_000_000
        /// HEVC Main10 with BT.2020 / HLG tagging.
        var hlg = false
        /// Stored in the track as preferredTransform (the coded frame stays landscape).
        var transform = CGAffineTransform.identity
        /// Non-square pixels: horizontal : vertical spacing.
        var pixelAspect: (Int, Int)?
        /// When longer than `seconds`, the audio track runs past the last video frame.
        var audioSeconds: Double?
        /// Last second fades to black, ending in a few fully black frames.
        var fadeToBlack = false
        /// Draws a bright block in the coded top-left so orientation is measurable.
        var marker = false
        /// Phone-like audio: 2 channels at 48 kHz.
        var audioChannels = 1
        var audioRate = 44100
    }

    static func cachedURL(name: String, width: Int = 1920, height: Int = 1080, seconds: Double = 10, fps: Int = 30, bitrate: Int = 12_000_000) async throws -> URL {
        var o = Options(); o.width = width; o.height = height; o.seconds = seconds; o.fps = fps; o.bitrate = bitrate
        return try await cachedURL(name: name, options: o)
    }

    static func cachedURL(name: String, options: Options) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).mp4")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).mp4")
        try await generate(to: tmp, options: options)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
        return url
    }

    static func hlgSupported(width: Int, height: Int) -> Bool {
        guard let w = try? AVAssetWriter(outputURL: FileManager.default.temporaryDirectory.appendingPathComponent("probe.mp4"), fileType: .mp4) else { return false }
        return w.canApply(outputSettings: videoSettings(Options(width: width, height: height, hlg: true)), forMediaType: .video)
    }

    private static func videoSettings(_ o: Options) -> [String: Any] {
        var props: [String: Any] = [AVVideoAverageBitRateKey: o.bitrate, AVVideoMaxKeyFrameIntervalKey: o.fps * 2]
        var settings: [String: Any] = [AVVideoWidthKey: o.width, AVVideoHeightKey: o.height]
        if o.hlg {
            settings[AVVideoCodecKey] = AVVideoCodecType.hevc
            props[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
            settings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ]
        } else {
            settings[AVVideoCodecKey] = AVVideoCodecType.h264
            props[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        if let (h, v) = o.pixelAspect {
            props[AVVideoPixelAspectRatioKey] = [AVVideoPixelAspectRatioHorizontalSpacingKey: h, AVVideoPixelAspectRatioVerticalSpacingKey: v]
        }
        settings[AVVideoCompressionPropertiesKey] = props
        return settings
    }

    static func generate(to url: URL, width: Int, height: Int, seconds: Double, fps: Int, bitrate: Int) async throws {
        var o = Options(); o.width = width; o.height = height; o.seconds = seconds; o.fps = fps; o.bitrate = bitrate
        try await generate(to: url, options: o)
    }

    static func generate(to url: URL, options o: Options) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings(o))
        vIn.transform = o.transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: o.width, kCVPixelBufferHeightKey as String: o.height,
        ])
        let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: o.audioRate, AVNumberOfChannelsKey: o.audioChannels, AVEncoderBitRateKey: 64_000 * o.audioChannels,
        ])
        guard writer.canAdd(vIn) else { throw NSError(domain: "Synthetic", code: 3, userInfo: [NSLocalizedDescriptionKey: "unsupported video settings"]) }
        writer.add(vIn); writer.add(aIn)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "Synthetic", code: 1) }
        writer.startSession(atSourceTime: .zero)

        let total = Int(o.seconds * Double(o.fps))
        let vq = DispatchQueue(label: "synthetic.video"), aq = DispatchQueue(label: "synthetic.audio")
        let group = DispatchGroup()

        group.enter()
        var frame = 0
        vIn.requestMediaDataWhenReady(on: vq) {
            while vIn.isReadyForMoreMediaData {
                if frame >= total { vIn.markAsFinished(); group.leave(); return }
                guard let pool = adaptor.pixelBufferPool else { continue }
                var pb: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
                guard let buffer = pb else { continue }
                draw(frame: frame, total: total, t: Double(frame) / Double(o.fps), into: buffer, o: o)
                adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(o.fps)))
                frame += 1
            }
        }

        group.enter()
        let sampleRate = o.audioRate
        let totalSamples = Int((o.audioSeconds ?? o.seconds) * Double(sampleRate))
        var sampleIndex = 0
        aIn.requestMediaDataWhenReady(on: aq) {
            while aIn.isReadyForMoreMediaData {
                if sampleIndex >= totalSamples { aIn.markAsFinished(); group.leave(); return }
                let n = min(sampleRate / 10, totalSamples - sampleIndex)
                if let sb = audioBuffer(start: sampleIndex, count: n, rate: sampleRate, channels: o.audioChannels) { aIn.append(sb) }
                sampleIndex += n
            }
        }

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in group.notify(queue: .global()) { c.resume() } }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? NSError(domain: "Synthetic", code: 2) }
    }

    private static func draw(frame: Int, total: Int, t: Double, into buffer: CVPixelBuffer, o: Options) {
        let width = o.width, height = o.height
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        let w = CGFloat(width), h = CGFloat(height)
        let hue = CGFloat(t.truncatingRemainder(dividingBy: 10) / 10)
        let top = CGColor(red: 0.1 + 0.4 * hue, green: 0.35, blue: 0.8 - 0.4 * hue, alpha: 1)
        let bottom = CGColor(red: 0.9 - 0.5 * hue, green: 0.55, blue: 0.2 + 0.3 * hue, alpha: 1)
        let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top, bottom] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])

        var seed: UInt64 = 12345
        func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat((seed >> 33) & 0xFFFF) / 65535 }
        for _ in 0..<90 {
            let sx = rnd() * w, sy = rnd() * h, vx = (rnd() - 0.5) * 600, vy = (rnd() - 0.5) * 400
            let size = 30 + rnd() * 160
            let x = (sx + vx * CGFloat(t)).truncatingRemainder(dividingBy: w + size)
            let y = (sy + vy * CGFloat(t)).truncatingRemainder(dividingBy: h + size)
            ctx.setFillColor(CGColor(red: rnd(), green: rnd(), blue: rnd(), alpha: 0.7))
            ctx.fillEllipse(in: CGRect(x: x < 0 ? x + w : x, y: y < 0 ? y + h : y, width: size, height: size * 0.7))
        }
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.22)); ctx.setLineWidth(2)
        let shift = CGFloat(t) * 140
        var x = -shift.truncatingRemainder(dividingBy: 14)
        while x < w { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x + 200, y: h)); x += 14 }
        ctx.strokePath()
        var fseed = UInt64(frame) &* 7919 &+ 1
        func frnd() -> CGFloat { fseed = fseed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat((fseed >> 33) & 0xFFFF) / 65535 }
        for _ in 0..<700 {
            ctx.setFillColor(CGColor(gray: frnd(), alpha: 0.5))
            ctx.fill(CGRect(x: frnd() * w, y: frnd() * h, width: 3, height: 3))
        }
        if o.marker {
            // CoreGraphics origin is bottom-left; this is the coded top-left corner.
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: h * 0.6, width: w * 0.4, height: h * 0.4))
        }
        if o.fadeToBlack {
            let fadeFrames = o.fps
            let into = frame - (total - fadeFrames)
            if into >= 0 {
                let alpha = into >= fadeFrames - 8 ? 1 : CGFloat(into) / CGFloat(fadeFrames - 8)
                ctx.setFillColor(CGColor(gray: 0, alpha: alpha))
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
    }

    private static func audioBuffer(start: Int, count: Int, rate: Int, channels: Int = 1) -> CMSampleBuffer? {
        var samples = [Int16](repeating: 0, count: count * channels)
        for i in 0..<count {
            let tt = Double(start + i) / Double(rate)
            for c in 0..<channels {
                samples[i * channels + c] = Int16(8000 * sin(2 * .pi * (330 + 110 * Double(c)) * tt) + 3000 * sin(2 * .pi * 1250 * tt))
            }
        }
        var asbd = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                               mBytesPerPacket: UInt32(2 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(2 * channels),
                                               mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 16, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt) == noErr, let fmt else { return nil }
        let bytes = count * 2 * channels
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr, let block else { return nil }
        _ = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
        var sb: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: fmt, sampleCount: count,
                                                                   presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(rate)),
                                                                   packetDescriptions: nil, sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }
}
#endif
