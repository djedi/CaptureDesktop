import AVFoundation
import CoreImage
import Vision

/// How the camera appears over the screen recording in the editor project.
struct CameraLayoutSettings: Codable, Equatable {
    enum Shape: String, Codable, CaseIterable, Identifiable {
        case rectangle = "Rectangle", circle = "Circle"
        var id: String { rawValue }
    }

    enum Corner: String, Codable, CaseIterable, Identifiable {
        case topLeft = "Top Left", topRight = "Top Right", bottomLeft = "Bottom Left", bottomRight = "Bottom Right"
        var id: String { rawValue }
        var isLeft: Bool { self == .topLeft || self == .bottomLeft }
        var isTop: Bool { self == .topLeft || self == .topRight }
    }

    var removeBackground = false
    var shape = Shape.rectangle
    /// Width of the camera picture as a fraction of the screen width.
    var size = 0.25
    var corner = Corner.bottomRight
    /// Gap to the screen edge, as a fraction of the screen width.
    var margin = 0.015

    /// A processed, transparent copy of the camera is needed for these looks.
    var needsProcessing: Bool { removeBackground || shape == .circle }

    private static let key = "cameraLayout.settings"

    static func load() -> CameraLayoutSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(CameraLayoutSettings.self, from: data) else { return .init() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    /// Where the camera sits in a picture of `size`, top-left origin. `aspect` is the camera's width / height.
    func frame(in size: CGSize, cameraAspect aspect: CGFloat) -> CGRect {
        let width = size.width * self.size
        let height = shape == .circle ? width : width / aspect
        let gap = size.width * margin
        return CGRect(x: corner.isLeft ? gap : size.width - width - gap,
                      y: corner.isTop ? gap : size.height - height - gap,
                      width: width, height: height)
    }

    /// What the Resolve script needs to place the camera.
    func resolveOptions(file: String) -> [String: Any] {
        ["file": file, "size": size, "margin": margin, "left": corner.isLeft, "top": corner.isTop,
         "square": shape == .circle]
    }
}

/// Writes a transparent copy of the camera recording: the person cut out of
/// the background, a circular crop, or both. The original file is untouched.
enum CameraProcessor {
    static let filePrefix = "camera-cutout"

    /// The parts of the layout that change the rendered picture (size and corner do not).
    private struct Look: Encodable {
        let removeBackground: Bool
        let shape: String
    }

    /// Each look gets its own file, which is never rewritten once it exists.
    static func fileName(for settings: CameraLayoutSettings) -> String {
        "\(filePrefix)-\(settingsTag(Look(removeBackground: settings.removeBackground, shape: settings.shape.rawValue))).mov"
    }

    static func render(source: URL, to url: URL, settings: CameraLayoutSettings,
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
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RecorderError("The camera recording has no video")
        }
        let size = try await track.load(.naturalSize)
        let assetDuration = try await asset.load(.duration)
        let duration = assetDuration.seconds
        let width = Int(size.width), height = Int(size.height)
        let extent = CGRect(x: 0, y: 0, width: width, height: height)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        // ProRes 4444, not HEVC with alpha: Resolve reads HEVC's alpha with a raised
        // floor, which leaves a faint veil over the whole camera frame.
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes4444, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw RecorderError("Cannot write the camera cutout") }
        writer.add(input)
        guard reader.startReading() else { throw reader.error ?? RecorderError("Cannot read the camera recording") }
        guard writer.startWriting() else { throw writer.error ?? RecorderError("Cannot write the camera cutout") }
        writer.startSession(atSourceTime: .zero)

        let context = CIContext(options: [.cacheIntermediates: false])
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let clear = CIImage(color: .clear).cropped(to: extent)

        // Reusing one request and one sequence handler lets Vision smooth the mask over time.
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNSequenceRequestHandler()

        var circle: CIImage?
        if settings.shape == .circle {
            let radius = CGFloat(min(width, height)) / 2
            circle = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: extent.midX, y: extent.midY),
                "inputRadius0": radius - 3, "inputRadius1": radius,
                "inputColor0": CIColor.white, "inputColor1": CIColor.black,
            ])?.outputImage?.cropped(to: extent)
        }

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let pixels = sample.imageBuffer else { continue }
            let time = sample.presentationTimeStamp
            var mask = circle
            if settings.removeBackground {
                try handler.perform([request], on: pixels)
                if let result = request.results?.first?.pixelBuffer {
                    var person = CIImage(cvPixelBuffer: result)
                    person = person.transformed(by: CGAffineTransform(
                        scaleX: extent.width / person.extent.width, y: extent.height / person.extent.height))
                    mask = circle.map { person.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? person
                } else {
                    // No segmentation for this frame: show nothing rather than the room.
                    mask = CIImage(color: .black).cropped(to: extent)
                }
            }
            var frame = CIImage(cvPixelBuffer: pixels)
            if let mask {
                frame = frame.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: mask,
                ])
            }
            while !input.isReadyForMoreMediaData {
                if writer.status != .writing { throw writer.error ?? RecorderError("Writing the camera cutout failed") }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else { throw RecorderError("Cannot allocate frames for the camera cutout") }
            var created: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
            guard let buffer = created else { throw RecorderError("Cannot allocate frames for the camera cutout") }
            context.render(frame.composited(over: clear), to: buffer, bounds: extent, colorSpace: colorSpace)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw writer.error ?? RecorderError("Writing the camera cutout failed")
            }
            if duration > 0 { progress(min(1, time.seconds / duration)) }
        }
        if reader.status == .failed { throw reader.error ?? RecorderError("Reading the camera recording failed") }
        input.markAsFinished()
        writer.endSession(atSourceTime: assetDuration)
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? RecorderError("Writing the camera cutout failed") }
        // If another render finished the same file meanwhile, keep that one.
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.moveItem(at: url, to: destination)
        }
        progress(1)
    }
}
