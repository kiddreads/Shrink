import Foundation
import UIKit
import os

/// Builds the text shown when something fails: a friendly line, then everything needed to diagnose it.
struct ErrorReport {
    var stage: Stage
    var error: Error
    var video: VideoInfo?
    var plan: EncodePlan?
    var codec: VideoCodec?
    var targetBytes: Int64?
    var keepAudio: Bool?

    private static let log = Logger(subsystem: "com.kiddreads.shrink", category: "error")

    var root: Error { (error as? StageError)?.underlying ?? error }

    var friendly: String {
        switch stage {
        case .load: return "Couldn't open that video."
        case .save: return "Couldn't save to Photos."
        case .verify: return "Shrink couldn't read the frames of this video."
        default: return "Compression stopped before it finished."
        }
    }

    /// Short text for the alert body.
    var summary: String {
        let ns = root as NSError
        if let c = root as? CompressorError, case .brokenOutput = c { return friendly }
        return "\(friendly)\n\(stage.rawValue): \(ns.domain) \(ns.code) (\(ns.localizedDescription))"
    }

    var details: String {
        var lines = [friendly, "Stage: \(stage.rawValue)"]
        let chain = Compressor.underlyingChain(root)
        lines.append("Error: \(chain[0].domain) \(chain[0].code) \"\(chain[0].localizedDescription)\"")
        for (i, e) in chain.dropFirst().enumerated() {
            lines.append("Underlying \(i + 1): \(e.domain) \(e.code) \"\(e.localizedDescription)\"")
        }
        if let reason = (root as NSError).localizedFailureReason { lines.append("Reason: \(reason)") }
        if let v = video {
            let s = v.source
            lines.append("Source: \(s.width)x\(s.height), \(v.codecName), \(v.bitDepth)-bit, HDR \(v.isHDR ? "yes" : "no"), \(String(format: "%.2f", s.fps)) fps, \(String(format: "%.1f", s.duration)) s, \(Format.bytes(s.bytes)), audio \(s.hasAudio ? "yes" : "no")")
        }
        var p = "Plan:"
        if let c = codec { p += " \(c.label)" }
        if let plan { p += " \(plan.width)x\(plan.height)@\(Int(plan.fps.rounded())) video \(plan.videoBitrate) bps audio \(plan.audioBitrate) bps" }
        if let t = targetBytes { p += " target \(Format.bytes(t))" }
        if let k = keepAudio { p += " keepAudio \(k)" }
        lines.append(p)
        let info = Bundle.main.infoDictionary
        lines.append("App: Shrink \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?")), iOS \(UIDevice.current.systemVersion), \(Self.deviceModel())")
        return lines.joined(separator: "\n")
    }

    func log() { Self.log.error("\(details, privacy: .public)") }

    static func deviceModel() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.machine", &buf, &size, nil, 0)
        return String(cString: buf)
    }
}
