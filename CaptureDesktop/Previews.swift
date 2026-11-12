import Accelerate
import AVFoundation
import ScreenCaptureKit
import SwiftUI

/// Which sources are switched on. Shared by the recorder window and the menu.
enum SourcePrefs {
    static let screenKey = "source.screen", cameraKey = "source.camera"
    static let microphoneKey = "source.microphone", systemAudioKey = "source.systemAudio"
    static let nativeResolutionKey = "capture.nativeResolution"
    /// Show the camera preview as a mirror image. The recording is never mirrored.
    static let mirrorCameraKey = "camera.mirrorPreview"

    static func isOn(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}

/// Collects the loudest sample seen since it was last read. Safe across threads.
final class LevelBox {
    private let lock = NSLock()
    private var peak: Float = 0

    func feed(_ sampleBuffer: CMSampleBuffer) {
        guard let block = sampleBuffer.dataBuffer else { return }
        // Preview audio is always 32-bit float, interleaved or planar.
        var samples = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
        guard !samples.isEmpty,
              CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: samples.count * 4, destination: &samples) == noErr else { return }
        var loudest: Float = 0
        vDSP_maxmgv(samples, 1, &loudest, vDSP_Length(samples.count))
        lock.lock()
        peak = max(peak, loudest)
        lock.unlock()
    }

    func take() -> Float {
        lock.lock()
        defer { lock.unlock() }
        let value = peak
        peak = 0
        return value
    }
}

/// Camera picture and microphone level while nothing is being recorded.
final class DevicePreview: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let microphoneLevel = LevelBox()
    private let queue = DispatchQueue(label: "top.capturedesk.preview")
    private var camera = false, microphone = false

    func configure(camera: Bool, microphone: Bool) {
        queue.async { [self] in
            guard camera != self.camera || microphone != self.microphone || !session.isRunning else { return }
            self.camera = camera
            self.microphone = microphone
            if session.isRunning { session.stopRunning() }
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            session.outputs.forEach(session.removeOutput)
            if camera, AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
               let device = AVCaptureDevice.default(for: .video),
               let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
            }
            if microphone, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
               let device = AVCaptureDevice.default(for: .audio),
               let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
                let output = AVCaptureAudioDataOutput()
                output.audioSettings = [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
                ]
                output.setSampleBufferDelegate(self, queue: queue)
                if session.canAddOutput(output) { session.addOutput(output) }
            }
            session.commitConfiguration()
            if !session.inputs.isEmpty { session.startRunning() }
        }
    }

    /// Returns once the devices are released, so a recording can take them.
    func stop() {
        queue.sync {
            camera = false
            microphone = false
            if session.isRunning { session.stopRunning() }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        microphoneLevel.feed(sampleBuffer)
    }
}

/// Everything the recorder window shows before a recording starts.
@MainActor
final class PreviewEngine: ObservableObject {
    static let shared = PreviewEngine()
    @Published private(set) var screenImage: CGImage?
    @Published private(set) var screenPermission = true
    /// Peak level per tick for the last few seconds, oldest first.
    @Published private(set) var microphoneHistory = [Float](repeating: 0, count: PreviewEngine.historyLength)
    @Published private(set) var systemHistory = [Float](repeating: 0, count: PreviewEngine.historyLength)
    private static let historyLength = 96
    let devices = DevicePreview()

    private var active = false
    private var thumbnailTask: Task<Void, Never>?
    private var levelTimer: Timer?
    private var systemMeter: ScreenSource?
    private var systemMeterBusy = false
    private let systemBox = LevelBox()
    private let meterQueue = DispatchQueue(label: "top.capturedesk.meter")

    func start() {
        guard !active else { return }
        active = true
        refresh()
        thumbnailTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.updateThumbnail()
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
        let timer = Timer(timeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.microphoneHistory = Array(self.microphoneHistory.dropFirst()) + [self.devices.microphoneLevel.take()]
                self.systemHistory = Array(self.systemHistory.dropFirst()) + [self.systemBox.take()]
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    /// Re-read the source switches and start or stop previews to match.
    func refresh() {
        guard active else { return }
        Task {
            // Ask for access the first time a source is switched on (at launch or
            // later), so its preview can appear; macOS only prompts while undecided.
            // Each switch is read right before its prompt: it may have been turned
            // off, or the window closed, while an earlier prompt was showing.
            if active, SourcePrefs.isOn(SourcePrefs.cameraKey), AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
            }
            if active, SourcePrefs.isOn(SourcePrefs.microphoneKey), AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            }
            guard active else { return }
            // Read the switches again: they may have changed while a prompt was up.
            devices.configure(camera: SourcePrefs.isOn(SourcePrefs.cameraKey),
                              microphone: SourcePrefs.isOn(SourcePrefs.microphoneKey))
            await syncSystemMeter()
        }
    }

    func stop() async {
        guard active else { return }
        active = false
        thumbnailTask?.cancel()
        thumbnailTask = nil
        levelTimer?.invalidate()
        levelTimer = nil
        devices.stop()
        while systemMeterBusy { try? await Task.sleep(nanoseconds: 20_000_000) }
        await syncSystemMeter()
        microphoneHistory = [Float](repeating: 0, count: Self.historyLength)
        systemHistory = [Float](repeating: 0, count: Self.historyLength)
    }

    private func syncSystemMeter() async {
        guard !systemMeterBusy else { return }
        systemMeterBusy = true
        defer { systemMeterBusy = false }
        // Starting and stopping take time, and the switch can change meanwhile, so
        // keep reconciling until the meter matches what is wanted (bounded, in case
        // the stream cannot start).
        for _ in 0..<4 {
            let wanted = active && SourcePrefs.isOn(SourcePrefs.systemAudioKey) && CGPreflightScreenCaptureAccess()
            if wanted == (systemMeter != nil) { return }
            if wanted {
                let meter = ScreenSource()
                let box = systemBox
                meter.onAudio = { sample, _ in box.feed(sample) }
                guard (try? await meter.start(target: .display(nil), video: false, systemAudio: true, fps: 30,
                                              showsCursor: false, nativeResolution: false, queue: meterQueue)) != nil else { return }
                systemMeter = meter
            } else if let meter = systemMeter {
                systemMeter = nil
                await meter.stop()
            }
        }
    }

    private func updateThumbnail() async {
        screenPermission = CGPreflightScreenCaptureAccess()
        guard active, screenPermission, SourcePrefs.isOn(SourcePrefs.screenKey),
              let target = CaptureSettings.shared.target,
              let resolved = try? await ScreenSource.resolve(target, nativeResolution: false) else {
            screenImage = nil
            return
        }
        let config = SCStreamConfiguration()
        let bounds = resolved.region.bounds
        config.width = 720
        config.height = max(16, Int(720 * bounds.height / max(bounds.width, 1)))
        if let sourceRect = resolved.sourceRect { config.sourceRect = sourceRect }
        config.ignoreShadowsSingleWindow = true
        config.showsCursor = true
        let image = try? await SCScreenshotManager.captureImage(contentFilter: resolved.filter, configuration: config)
        if active { screenImage = image }
    }
}

/// The live camera picture, optionally flipped left to right like a mirror.
struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession
    var mirrored = false

    func makeNSView(context: Context) -> CameraPreviewNSView {
        let view = CameraPreviewNSView(session: session)
        view.mirrored = mirrored
        return view
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        nsView.mirrored = mirrored
    }
}

final class CameraPreviewNSView: NSView {
    private let preview: AVCaptureVideoPreviewLayer
    var mirrored = false { didSet { if mirrored != oldValue { needsLayout = true } } }

    init(session: AVCaptureSession) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        preview.videoGravity = .resizeAspectFill
        let backing = CALayer()
        backing.backgroundColor = NSColor.black.cgColor
        backing.masksToBounds = true
        backing.addSublayer(preview)
        layer = backing
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        // The flip is a transform on the layer, so it holds however the camera
        // connection is rebuilt when sources are switched on and off.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.transform = CATransform3DIdentity
        preview.frame = bounds
        preview.transform = mirrored ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity
        CATransaction.commit()
    }
}
