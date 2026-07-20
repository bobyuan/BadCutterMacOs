import Foundation
import AVFoundation
import QuartzCore

/// One file to render: a reel (many segments) or an individual clip (one).
struct ExportJob {
    var label: String
    var outputURL: URL
    var segments: [TimeSegment]
    /// Optional overlay text per segment (aligned with `segments`). Non-nil
    /// entries are burned in (forces a re-encode).
    var overlayTexts: [String?]?
    /// Crossfade duration between segments; 0 = hard cut. > 0 forces a re-encode.
    var crossfade: TimeInterval

    init(label: String, outputURL: URL, segments: [TimeSegment],
         overlayTexts: [String?]? = nil, crossfade: TimeInterval = 0) {
        self.label = label
        self.outputURL = outputURL
        self.segments = segments
        self.overlayTexts = overlayTexts
        self.crossfade = crossfade
    }

    var needsComposition: Bool {
        crossfade > 0 || overlayTexts?.contains(where: { $0 != nil }) == true
    }
}

final class VideoExporter {

    /// Render each job to disk sequentially. `matchSourceFormat` tries a
    /// passthrough export (keeps the source codec, cuts land on keyframes);
    /// it falls back to a highest-quality re-encode when passthrough fails.
    /// Jobs with crossfade or overlays always re-encode.
    func run(
        jobs: [ExportJob],
        assetURL: URL,
        matchSourceFormat: Bool,
        onProgress: @MainActor @escaping (String) -> Void
    ) async throws -> [ExportOutput] {
        var outputs: [ExportOutput] = []
        for (index, job) in jobs.enumerated() {
            await onProgress("Exporting \(job.label) (\(index + 1)/\(jobs.count))…")
            let url: URL
            if job.needsComposition {
                url = try await exportComposed(job: job, assetURL: assetURL)
            } else {
                url = try await exportSimple(
                    segments: job.segments,
                    assetURL: assetURL,
                    outputURL: job.outputURL,
                    matchSourceFormat: matchSourceFormat
                )
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            var duration = job.segments.reduce(0) { $0 + $1.duration }
            if job.crossfade > 0, job.segments.count > 1 {
                duration -= job.crossfade * Double(job.segments.count - 1)
            }
            outputs.append(ExportOutput(label: job.label, url: url, duration: duration, fileSize: size ?? 0))
        }
        return outputs
    }

    // MARK: - Simple Cut Export

    private func exportSimple(
        segments: [TimeSegment],
        assetURL: URL,
        outputURL: URL,
        matchSourceFormat: Bool
    ) async throws -> URL {
        let valid = segments.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        guard !valid.isEmpty else {
            throw NSError(domain: "VideoExporter", code: 7, userInfo: [NSLocalizedDescriptionKey: "Nothing selected to export."])
        }

        let asset = AVURLAsset(url: assetURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "VideoExporter", code: 1, userInfo: [NSLocalizedDescriptionKey: "No video track found"])
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first

        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "VideoExporter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create composition track"])
        }
        compVideo.preferredTransform = try await videoTrack.load(.preferredTransform)
        let compAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var cursor = CMTime.zero
        for s in valid {
            let range = CMTimeRange(
                start: CMTime(seconds: s.start, preferredTimescale: 600),
                end: CMTime(seconds: s.end, preferredTimescale: 600)
            )
            try compVideo.insertTimeRange(range, of: videoTrack, at: cursor)
            if let audioTrack, let compAudio {
                try? compAudio.insertTimeRange(range, of: audioTrack, at: cursor)
            }
            cursor = cursor + range.duration
        }

        if matchSourceFormat {
            do {
                return try await runSession(asset: composition, preset: AVAssetExportPresetPassthrough, outputURL: outputURL)
            } catch {
                // Passthrough is codec-dependent — fall through to re-encode.
            }
        }
        return try await runSession(asset: composition, preset: AVAssetExportPresetHighestQuality, outputURL: outputURL)
    }

    // MARK: - Composed Export (crossfade and/or score overlay)

    private func exportComposed(job: ExportJob, assetURL: URL) async throws -> URL {
        let valid = job.segments.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        guard !valid.isEmpty else {
            throw NSError(domain: "VideoExporter", code: 7, userInfo: [NSLocalizedDescriptionKey: "Nothing selected to export."])
        }

        let asset = AVURLAsset(url: assetURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "VideoExporter", code: 1, userInfo: [NSLocalizedDescriptionKey: "No video track found"])
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let frameRate = try await videoTrack.load(.nominalFrameRate)
        let renderSize = CGRect(origin: .zero, size: naturalSize).applying(transform).standardized.size

        // Cap the crossfade so it never exceeds half of the shortest segment.
        var fade = job.crossfade
        if fade > 0 {
            let shortest = valid.map(\.duration).min() ?? 0
            fade = min(fade, shortest / 2)
            if fade < 0.1 { fade = 0 }
        }

        let composition = AVMutableComposition()
        // Alternating A/B tracks make the overlap regions possible.
        let videoTracks = [
            composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
            composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        ].compactMap { $0 }
        let audioTracks = [
            composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
            composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        ].compactMap { $0 }
        guard videoTracks.count == 2 else {
            throw NSError(domain: "VideoExporter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create composition tracks"])
        }

        // Insert segments; each starts `fade` before the previous one ends.
        var starts: [CMTime] = []
        var cursor = CMTime.zero
        let fadeCM = CMTime(seconds: fade, preferredTimescale: 600)
        for (i, s) in valid.enumerated() {
            let range = CMTimeRange(
                start: CMTime(seconds: s.start, preferredTimescale: 600),
                end: CMTime(seconds: s.end, preferredTimescale: 600)
            )
            let track = videoTracks[i % 2]
            try track.insertTimeRange(range, of: videoTrack, at: cursor)
            if let audioTrack, i % 2 < audioTracks.count {
                try? audioTracks[i % 2].insertTimeRange(range, of: audioTrack, at: cursor)
            }
            starts.append(cursor)
            cursor = cursor + range.duration - fadeCM
        }
        let totalDuration = cursor + fadeCM

        // Video composition instructions: solo regions + crossfade overlaps.
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(24, frameRate.rounded())))

        func layerInstruction(trackIndex: Int) -> AVMutableVideoCompositionLayerInstruction {
            let instruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTracks[trackIndex])
            instruction.setTransform(transform, at: .zero)
            return instruction
        }

        var instructions: [AVMutableVideoCompositionInstruction] = []
        for i in valid.indices {
            let segStart = starts[i]
            let segEnd = segStart + CMTime(seconds: valid[i].duration, preferredTimescale: 600)
            let soloStart = i == 0 ? segStart : segStart + fadeCM
            let soloEnd = i == valid.count - 1 ? segEnd : starts[i + 1]

            if soloEnd > soloStart {
                let solo = AVMutableVideoCompositionInstruction()
                solo.timeRange = CMTimeRange(start: soloStart, end: soloEnd)
                solo.layerInstructions = [layerInstruction(trackIndex: i % 2)]
                instructions.append(solo)
            }

            if fade > 0, i < valid.count - 1 {
                let overlapRange = CMTimeRange(start: starts[i + 1], duration: fadeCM)
                let outgoing = layerInstruction(trackIndex: i % 2)
                outgoing.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: overlapRange)
                let incoming = layerInstruction(trackIndex: (i + 1) % 2)
                let overlap = AVMutableVideoCompositionInstruction()
                overlap.timeRange = overlapRange
                overlap.layerInstructions = [outgoing, incoming]
                instructions.append(overlap)
            }
        }
        videoComposition.instructions = instructions

        // Audio crossfade mirrors the video opacity ramps.
        var audioMix: AVMutableAudioMix?
        if fade > 0, !audioTracks.isEmpty {
            let mix = AVMutableAudioMix()
            mix.inputParameters = audioTracks.enumerated().map { trackIndex, track in
                let params = AVMutableAudioMixInputParameters(track: track)
                for i in valid.indices where i % 2 == trackIndex {
                    if i > 0 {
                        params.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1,
                                             timeRange: CMTimeRange(start: starts[i], duration: fadeCM))
                    }
                    if i < valid.count - 1 {
                        params.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0,
                                             timeRange: CMTimeRange(start: starts[i + 1], duration: fadeCM))
                    }
                }
                return params
            }
            audioMix = mix
        }

        // Score overlay: one timed text layer per segment.
        if let texts = job.overlayTexts, texts.contains(where: { $0 != nil }) {
            let parentLayer = CALayer()
            let videoLayer = CALayer()
            parentLayer.frame = CGRect(origin: .zero, size: renderSize)
            videoLayer.frame = parentLayer.frame
            parentLayer.addSublayer(videoLayer)

            for i in valid.indices {
                guard i < texts.count, let text = texts[i] else { continue }
                let begin = max(CMTimeGetSeconds(starts[i]), 0.01)
                let duration = valid[i].duration - (i < valid.count - 1 ? fade : 0)
                parentLayer.addSublayer(Self.scoreLayer(
                    text: text,
                    renderSize: renderSize,
                    beginTime: AVCoreAnimationBeginTimeAtZero + begin,
                    duration: max(0.1, duration)
                ))
            }
            videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
                postProcessingAsVideoLayer: videoLayer, in: parentLayer)
        }

        _ = totalDuration
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "VideoExporter", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create export session"])
        }
        session.videoComposition = videoComposition
        session.audioMix = audioMix
        return try await runConfiguredSession(session, outputURL: job.outputURL)
    }

    /// Score badge: rounded dark pill, bottom-left, visible only during its
    /// point. The text is pre-rendered into the layer's contents — CATextLayer
    /// is unreliable inside AVVideoCompositionCoreAnimationTool's renderer.
    private static func scoreLayer(text: String, renderSize: CGSize, beginTime: CFTimeInterval, duration: CFTimeInterval) -> CALayer {
        let fontSize = max(24, renderSize.height * 0.045)
        let padding = fontSize * 0.5
        let size = CGSize(width: CGFloat(text.count) * fontSize * 0.62 + padding * 2,
                          height: fontSize * 1.6)

        let pill = CALayer()
        pill.frame = CGRect(x: renderSize.width * 0.03, y: renderSize.height * 0.05,
                            width: size.width, height: size.height)
        pill.contents = renderBadgeImage(text: text, size: size, fontSize: fontSize)
        pill.contentsGravity = .resize

        // Visible only within [beginTime, beginTime + duration].
        pill.opacity = 0
        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = 1
        appear.toValue = 1
        appear.beginTime = beginTime
        appear.duration = duration
        appear.isRemovedOnCompletion = false
        appear.fillMode = .removed
        pill.add(appear, forKey: "visibility")
        return pill
    }

    private static func renderBadgeImage(text: String, size: CGSize, fontSize: CGFloat) -> CGImage? {
        let scale: CGFloat = 2
        guard let ctx = CGContext(
            data: nil,
            width: Int(size.width * scale), height: Int(size.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.scaleBy(x: scale, y: scale)

        let bounds = CGRect(origin: .zero, size: size)
        let pillPath = CGPath(roundedRect: bounds, cornerWidth: fontSize * 0.4, cornerHeight: fontSize * 0.4, transform: nil)
        ctx.addPath(pillPath)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
        ctx.fillPath()

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 1)
        ]
        let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        let lineBounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        ctx.textPosition = CGPoint(
            x: (size.width - lineBounds.width) / 2 - lineBounds.origin.x,
            y: (size.height - lineBounds.height) / 2 - lineBounds.origin.y
        )
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }

    // MARK: - Session Running

    private func runSession(asset: AVAsset, preset: String, outputURL: URL) async throws -> URL {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw NSError(domain: "VideoExporter", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create export session"])
        }
        return try await runConfiguredSession(session, outputURL: outputURL)
    }

    private func runConfiguredSession(_ session: AVAssetExportSession, outputURL: URL) async throws -> URL {
        try? FileManager.default.removeItem(at: outputURL)
        session.outputURL = outputURL
        session.outputFileType = .mov
        session.shouldOptimizeForNetworkUse = false

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.exportAsynchronously {
                switch session.status {
                case .completed: continuation.resume(returning: ())
                case .failed:
                    continuation.resume(throwing: session.error ?? NSError(domain: "VideoExporter", code: 4))
                case .cancelled:
                    continuation.resume(throwing: NSError(domain: "VideoExporter", code: 5, userInfo: [NSLocalizedDescriptionKey: "Export cancelled"]))
                default:
                    continuation.resume(throwing: NSError(domain: "VideoExporter", code: 6, userInfo: [NSLocalizedDescriptionKey: "Export ended in unexpected state"]))
                }
            }
        }
        return outputURL
    }
}
