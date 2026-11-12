import AVFoundation
import CoreGraphics
import CryptoKit
import SwiftUI

/// A short, stable tag for a settings value, used in rendered file names.
func settingsTag<Settings: Encodable>(_ settings: Settings) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = (try? encoder.encode(settings)) ?? Data()
    // 64 bits: an existing file is trusted to be this look, so collisions must be out of the question.
    return SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
}

/// A colour that can be saved in preferences.
struct RGBA: Codable, Equatable {
    var r: Double, g: Double, b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    init(_ color: Color) {
        let converted = NSColor(color).usingColorSpace(.sRGB) ?? .yellow
        r = Double(converted.redComponent); g = Double(converted.greenComponent); b = Double(converted.blueComponent)
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b) }

    func cgColor(alpha: Double) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: alpha)
    }
}

/// How the cursor highlight and click ripples look. Sizes are in screen points.
struct CursorEffectSettings: Codable, Equatable {
    var highlight = true
    var highlightColor = RGBA(1.0, 0.84, 0.1)
    var highlightRadius = 30.0
    var highlightOpacity = 0.4
    var clicks = true
    var leftClickColor = RGBA(1.0, 0.27, 0.27)
    var rightClickColor = RGBA(0.25, 0.6, 1.0)

    var isActive: Bool { highlight || clicks }

    private static let key = "cursorEffects.settings"

    static func load() -> CursorEffectSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(CursorEffectSettings.self, from: data) else { return .init() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// The mouse log of one recording, in points of the recorded picture (top-left origin).
struct CursorTrack {
    struct Move { let t: Double, x: Double, y: Double, inside: Bool }
    struct Click { let t: Double, x: Double, y: Double, right: Bool }

    let moves: [Move]
    let clicks: [Click]
    /// Size of the recorded picture in points.
    let size: CGSize

    /// The recorded picture's size in points, read from the recording's details.
    /// Available even when there is no usable mouse log.
    static func pictureSize(_ folder: URL) -> CGSize? {
        guard let json = (try? Data(contentsOf: folder.appendingPathComponent("session.json")))
                .flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
              let capture = json["capture"] as? [String: Any],
              (json["tracks"] as? [String: Any])?["screen"] != nil,
              let width = capture["pixelWidth"] as? Int, let height = capture["pixelHeight"] as? Int,
              let scale = capture["scale"] as? Double, scale > 0 else { return nil }
        return CGSize(width: Double(width) / scale, height: Double(height) / scale)
    }
    let fps: Int32
    let frames: Int

    static func load(_ folder: URL) -> CursorTrack? {
        guard let json = (try? Data(contentsOf: folder.appendingPathComponent("session.json")))
                .flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
              let capture = json["capture"] as? [String: Any],
              let width = capture["pixelWidth"] as? Int, let height = capture["pixelHeight"] as? Int,
              let scale = capture["scale"] as? Double, scale > 0,
              let screen = (json["tracks"] as? [String: [String: Any]])?["screen"],
              let frames = screen["frames"] as? Int, frames > 0,
              let text = try? String(contentsOf: folder.appendingPathComponent("cursor.jsonl"), encoding: .utf8) else { return nil }
        var moves: [Move] = [], clicks: [Click] = []
        for line in text.split(separator: "\n") {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let t = event["t"] as? Double, let x = event["x"] as? Double, let y = event["y"] as? Double,
                  let type = event["type"] as? String else { continue }
            let inside = event["inside"] as? Bool ?? true
            switch type {
            case "move": moves.append(Move(t: t, x: x / scale, y: y / scale, inside: inside))
            case "down" where inside: clicks.append(Click(t: t, x: x / scale, y: y / scale, right: event["button"] as? String == "right"))
            default: break
            }
        }
        guard !moves.isEmpty else { return nil }
        // The log is written in time order; sort anyway so the searches can rely on it.
        moves.sort { $0.t < $1.t }
        clicks.sort { $0.t < $1.t }
        return CursorTrack(moves: moves, clicks: clicks,
                           size: CGSize(width: Double(width) / scale, height: Double(height) / scale),
                           fps: Int32(json["fps"] as? Int ?? 30), frames: frames)
    }

    /// Index of the first click later than `t` (clicks are sorted by time).
    func firstClickIndex(after t: Double) -> Int {
        var low = 0, high = clicks.count
        while low < high {
            let mid = (low + high) / 2
            if clicks[mid].t <= t { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Where the cursor was at time `t`: the last logged position at or before it,
    /// or nil before the pointer first entered the recorded area.
    func position(at t: Double) -> Move? {
        var low = 0, high = moves.count - 1, found = -1
        while low <= high {
            let mid = (low + high) / 2
            if moves[mid].t <= t { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        return found >= 0 ? moves[found] : nil
    }
}

/// Draws the effects for one instant. Used by both the live preview and the
/// renderer, so what you preview is what gets rendered.
enum CursorEffectPainter {
    static let rippleDuration = 0.45

    /// `context` must be set up in picture points with a top-left origin.
    static func draw(in context: CGContext, track: CursorTrack, time: Double, settings: CursorEffectSettings) {
        if settings.highlight, let cursor = track.position(at: time), cursor.inside {
            let center = CGPoint(x: cursor.x, y: cursor.y)
            let radius = settings.highlightRadius
            let colors = [
                settings.highlightColor.cgColor(alpha: settings.highlightOpacity),
                settings.highlightColor.cgColor(alpha: settings.highlightOpacity),
                settings.highlightColor.cgColor(alpha: 0),
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.72, 1]) {
                context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
            }
        }
        guard settings.clicks else { return }
        // Clicks are in time order: jump to the first one still rippling and stop
        // at the first one in the future, so cost does not grow with the recording.
        for click in track.clicks[track.firstClickIndex(after: time - rippleDuration)...] {
            if click.t > time { break }
            let progress = (time - click.t) / rippleDuration
            let radius = settings.highlightRadius * (0.5 + 1.3 * progress)
            let color = click.right ? settings.rightClickColor : settings.leftClickColor
            context.setStrokeColor(color.cgColor(alpha: 0.95 * (1 - progress)))
            context.setLineWidth(max(2, settings.highlightRadius * 0.16 * (1 - 0.5 * progress)))
            context.strokeEllipse(in: CGRect(x: click.x - radius, y: click.y - radius, width: radius * 2, height: radius * 2))
        }
    }
}

/// Writes the effects as a transparent video the same length as the screen
/// recording, to be layered above it in an editor.
enum CursorEffectRenderer {
    static let filePrefix = "cursor-effects"

    /// Each look gets its own file, named after its settings. A file is never
    /// rewritten once it exists, so an editor project that imported it keeps
    /// looking the way it did when it was made.
    static func fileName(for settings: CursorEffectSettings) -> String {
        "\(filePrefix)-\(settingsTag(settings)).mov"
    }

    static func render(track: CursorTrack, settings: CursorEffectSettings, to url: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        // A finished layer is never rewritten: an editor project may reference it.
        // Each look has its own file name, so an existing file is already this look.
        let destination = url
        if FileManager.default.fileExists(atPath: destination.path) {
            progress(1)
            return
        }
        // Write beside the destination and move it in only once complete, so a
        // failed or cancelled render never leaves a partial file under the real name.
        let url = destination.deletingLastPathComponent().appendingPathComponent(".rendering-\(UUID().uuidString)-" + destination.lastPathComponent)
        try? FileManager.default.removeItem(at: url)
        defer { try? FileManager.default.removeItem(at: url) }
        // Rendered at 1x: the effects are soft shapes, and transparent 4K ProRes is large.
        let width = max(16, Int(track.size.width) & ~1), height = max(16, Int(track.size.height) & ~1)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes4444, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw RecorderError("Cannot write the cursor effects layer") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? RecorderError("Cannot write the cursor effects layer") }
        writer.startSession(atSourceTime: .zero)

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        for frame in 0..<track.frames {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData {
                if writer.status != .writing { throw writer.error ?? RecorderError("Writing the cursor effects layer failed") }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else { throw RecorderError("Cannot allocate frames for the cursor effects layer") }
            var created: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
            guard let buffer = created else { throw RecorderError("Cannot allocate frames for the cursor effects layer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
                memset(base, 0, rowBytes * height)
                if let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                           bytesPerRow: rowBytes, space: colorSpace, bitmapInfo: bitmapInfo) {
                    // Flip to a top-left origin and scale picture points to this layer's pixels.
                    context.translateBy(x: 0, y: CGFloat(height))
                    context.scaleBy(x: CGFloat(width) / track.size.width, y: -CGFloat(height) / track.size.height)
                    CursorEffectPainter.draw(in: context, track: track, time: Double(frame) / Double(track.fps), settings: settings)
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: track.fps)) else {
                throw writer.error ?? RecorderError("Writing the cursor effects layer failed")
            }
            if frame % 15 == 0 { progress(Double(frame) / Double(track.frames)) }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(track.frames), timescale: track.fps))
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? RecorderError("Writing the cursor effects layer failed") }
        // If another render finished the same file meanwhile, keep that one.
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.moveItem(at: url, to: destination)
        }
        progress(1)
    }
}
