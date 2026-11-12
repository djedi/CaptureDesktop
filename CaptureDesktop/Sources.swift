import AVFoundation
import CoreGraphics
import ScreenCaptureKit

/// What part of the screen to record.
enum CaptureTarget: Equatable {
    /// A whole display; `nil` means the main display.
    case display(CGDirectDisplayID?)
    /// One window, followed as it moves.
    case window(CGWindowID)
    /// A rectangle on a display, in points relative to that display's top-left corner.
    case area(display: CGDirectDisplayID, rect: CGRect)

    var isWindow: Bool { if case .window = self { return true } else { return false } }
}

/// The recorded rectangle, used to map cursor positions into the picture.
struct CaptureRegion {
    let kind: String
    /// Global bounds in points, top-left origin (CoreGraphics display space).
    let bounds: CGRect
    /// Picture pixels per point.
    let scale: Double
    let pixelWidth: Int
    let pixelHeight: Int
    /// Set for window capture, so the cursor log can follow the window as it moves.
    var windowID: CGWindowID?
}

struct WindowItem: Identifiable, Hashable {
    let id: CGWindowID
    let app: String
    let title: String
    var label: String { title.isEmpty ? app : "\(app) — \(title)" }

    /// Normal, visible application windows, excluding CaptureDesktop's own.
    static func load() async -> [WindowItem] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return [] }
        return content.windows.compactMap { window in
            guard window.windowLayer == 0, window.frame.width >= 120, window.frame.height >= 80,
                  let app = window.owningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier,
                  !app.applicationName.isEmpty else { return nil }
            return WindowItem(id: window.windowID, app: app.applicationName, title: window.title ?? "")
        }
    }
}

/// Screen video and system audio from ScreenCaptureKit.
/// Timestamps are already on the host clock.
final class ScreenSource: NSObject, SCStreamOutput, SCStreamDelegate {
    var onVideo: ((CVPixelBuffer, CMTime) -> Void)?
    var onAudio: ((CMSampleBuffer, CMTime) -> Void)?
    var onError: ((Error) -> Void)?
    private var stream: SCStream?
    private var wantsVideo = false

    func start(target: CaptureTarget, video: Bool, systemAudio: Bool, fps: Int32, showsCursor: Bool,
               nativeResolution: Bool, queue: DispatchQueue) async throws -> CaptureRegion {
        let resolved = try await Self.resolve(target, nativeResolution: nativeResolution)
        let config = SCStreamConfiguration()
        if let sourceRect = resolved.sourceRect { config.sourceRect = sourceRect }
        config.ignoreShadowsSingleWindow = true
        let filter = resolved.filter
        let pixelWidth = resolved.region.pixelWidth, pixelHeight = resolved.region.pixelHeight

        if video {
            config.width = pixelWidth
            config.height = pixelHeight
            config.minimumFrameInterval = CMTime(value: 1, timescale: fps)
        } else {
            // Audio needs a stream, so capture a token-sized picture and ignore it.
            config.width = 16
            config.height = 16
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        }
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorSpaceName = CGColorSpace.sRGB
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.showsCursor = showsCursor
        config.queueDepth = 8
        config.capturesAudio = systemAudio
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true

        wantsVideo = video
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if systemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        try await stream.startCapture()
        self.stream = stream
        return resolved.region
    }

    struct ResolvedTarget {
        let filter: SCContentFilter
        /// Set for area capture: the rectangle within the display, in points.
        let sourceRect: CGRect?
        let region: CaptureRegion
    }

    /// Turns a capture target into a ScreenCaptureKit filter and the rectangle it covers.
    static func resolve(_ target: CaptureTarget, nativeResolution: Bool) async throws -> ResolvedTarget {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        // Keep CaptureDesktop's own windows and area outline out of the picture.
        let ownApp = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        func findDisplay(_ id: CGDirectDisplayID?) throws -> SCDisplay {
            // A display that was chosen explicitly must still be there: recording
            // some other screen instead could capture the wrong content.
            if let id {
                guard let display = content.displays.first(where: { $0.displayID == id }) else {
                    throw RecorderError("The selected display is no longer connected. Choose what to record again.")
                }
                return display
            }
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                throw RecorderError("No display available to capture")
            }
            return display
        }

        let filter: SCContentFilter
        let bounds: CGRect
        let kind: String
        var sourceRect: CGRect?
        switch target {
        case .display(let id):
            let display = try findDisplay(id)
            filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])
            bounds = CGDisplayBounds(display.displayID)
            kind = "display"
        case .area(let id, let rect):
            let display = try findDisplay(id)
            let displayBounds = CGDisplayBounds(display.displayID)
            let clipped = rect.integral.intersection(CGRect(origin: .zero, size: displayBounds.size))
            guard clipped.width >= 16, clipped.height >= 16 else { throw RecorderError("The selected area is too small") }
            filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])
            sourceRect = clipped
            bounds = clipped.offsetBy(dx: displayBounds.minX, dy: displayBounds.minY)
            kind = "area"
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw RecorderError("That window is no longer open. Pick another window.")
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            bounds = window.frame
            kind = "window"
        }
        let scale = nativeResolution ? Double(filter.pointPixelScale) : 1.0
        // Encoders want even dimensions.
        var region = CaptureRegion(
            kind: kind, bounds: bounds, scale: scale,
            pixelWidth: max(16, Int(bounds.width * scale) & ~1),
            pixelHeight: max(16, Int(bounds.height * scale) & ~1))
        if case .window(let id) = target { region.windowID = id }
        return ResolvedTarget(filter: filter, sourceRect: sourceRect, region: region)
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            guard wantsVideo,
                  let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: raw) == .complete,
                  let pixelBuffer = sampleBuffer.imageBuffer else { return }
            onVideo?(pixelBuffer, sampleBuffer.presentationTimeStamp)
        case .audio:
            onAudio?(sampleBuffer, sampleBuffer.presentationTimeStamp)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }
}

/// Camera video and microphone audio from one AVCaptureSession.
/// Timestamps are converted from the session clock to the host clock.
/// The cameras that can be recorded, and which one the user chose.
enum CameraChoice {
    /// Saved unique ID of the chosen camera. Empty means "the system default".
    static let idKey = "camera.deviceID"
    /// Saved name of the chosen camera, so it can still be named after it is unplugged.
    static let nameKey = "camera.deviceName"

    static var selectedID: String? {
        let id = UserDefaults.standard.string(forKey: idKey) ?? ""
        return id.isEmpty ? nil : id
    }

    /// Connected cameras, built-in first. Desk View is left out: it is a second
    /// view from a camera that is already listed.
    static func connected() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    /// The camera macOS prefers (the one the user last picked system-wide, or its
    /// automatic choice), falling back to the first camera found.
    static var systemDefault: AVCaptureDevice? {
        AVCaptureDevice.systemPreferredCamera ?? AVCaptureDevice.default(for: .video)
    }

    /// The camera to use: the chosen one, or the system default when none was chosen.
    /// A chosen camera that is not connected is an error. Another camera is never
    /// used in its place, so a recording cannot show an unexpected view.
    static func resolve(_ id: String?) throws -> AVCaptureDevice {
        guard let id else {
            guard let device = systemDefault else { throw RecorderError("No camera found") }
            return device
        }
        guard let device = connected().first(where: { $0.uniqueID == id }) else {
            let name = UserDefaults.standard.string(forKey: nameKey) ?? "The chosen camera"
            throw RecorderError("\(name) is not connected. Connect it or choose another camera.")
        }
        return device
    }
}

final class DeviceSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    var onVideo: ((CVPixelBuffer, CMTime) -> Void)?
    var onAudio: ((CMSampleBuffer, CMTime) -> Void)?
    /// Called when the session fails or a device in use is unplugged.
    var onError: ((Error) -> Void)?
    private let session = AVCaptureSession()
    private var observers: [NSObjectProtocol] = []
    private var devices: [AVCaptureDevice] = []
    private var videoOutput: AVCaptureVideoDataOutput?
    private(set) var cameraName: String?
    private(set) var microphoneName: String?

    /// `cameraID` picks a camera by unique ID; `nil` uses the system default.
    func start(camera: Bool, cameraID: String? = nil, microphone: Bool, queue: DispatchQueue) throws {
        // Resolve the camera before touching the session, so a missing one changes nothing.
        let cameraDevice = camera ? try CameraChoice.resolve(cameraID) : nil
        session.beginConfiguration()
        if let device = cameraDevice {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw RecorderError("Cannot use camera \(device.localizedName)") }
            session.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else { throw RecorderError("Cannot read frames from camera") }
            session.addOutput(output)
            videoOutput = output
            cameraName = device.localizedName
            devices.append(device)
        }
        if microphone {
            guard let device = AVCaptureDevice.default(for: .audio) else { throw RecorderError("No microphone found") }
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw RecorderError("Cannot use microphone \(device.localizedName)") }
            session.addInput(input)
            let output = AVCaptureAudioDataOutput()
            // Convert to 48 kHz float here so every audio track shares one rate.
            output.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else { throw RecorderError("Cannot read audio from microphone") }
            session.addOutput(output)
            microphoneName = device.localizedName
            devices.append(device)
        }
        session.commitConfiguration()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.onError?(error ?? RecorderError("The camera/microphone session failed"))
        })
        for device in devices {
            observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { [weak self] _ in
                self?.onError?(RecorderError("\(device.localizedName) was disconnected"))
            })
        }
        session.startRunning()
        guard session.isRunning else { throw RecorderError("Camera/microphone session did not start") }
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if session.isRunning { session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        var pts = sampleBuffer.presentationTimeStamp
        if let clock = session.synchronizationClock {
            pts = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock())
        }
        // Some cameras stamp their first frame with time zero; a frame that
        // far from "now" cannot be placed on the timeline, so skip it.
        guard pts.isNumeric, abs((hostNow() - pts).seconds) < 2 else { return }
        if output === videoOutput {
            if let pixelBuffer = sampleBuffer.imageBuffer { onVideo?(pixelBuffer, pts) }
        } else {
            onAudio?(sampleBuffer, pts)
        }
    }
}

/// Mouse position and button log, one JSON object per line.
///
/// Polls at 120 Hz rather than installing an event tap, so it needs no
/// Accessibility or Input Monitoring permission. Coordinates are pixels in the
/// recorded picture (top-left origin), ready to drive zoom and click effects.
final class CursorLogger {
    private let queue = DispatchQueue(label: "top.capturedesk.cursor", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var handle: FileHandle?
    private var buffer = Data()
    private var lastPoint = CGPoint(x: -1e9, y: -1e9)
    private var lastInside = false
    private var lastRawLocation = CGPoint(x: -1e9, y: -1e9)
    private var covered = false
    private let limitLock = NSLock()
    private var limit: Double?
    private var pollCount = 0
    private var lastButtons: [Bool] = [false, false]
    private(set) var events = 0
    /// The first failure to write the log, if any. Read after `stop()`.
    private(set) var writeError: Error?

    private static let passThroughLock = NSLock()
    private static var passThroughWindows: Set<Int> = []

    /// Marks one of CaptureDesktop's own windows as click-through (the area
    /// outline), so it is not mistaken for something covering the recorded window.
    static func registerPassThroughWindow(_ number: Int) {
        passThroughLock.lock()
        passThroughWindows.insert(number)
        passThroughLock.unlock()
    }

    /// True when a window that takes the pointer sits above `id` at `point`:
    /// a normal window of any app, or any CaptureDesktop window that is not click-through
    /// (its controls are never in the video).
    /// With no `id` (display or area capture) only CaptureDesktop's own windows count.
    private static func isCovered(_ id: CGWindowID?, at point: CGPoint) -> Bool {
        let options: CGWindowListOption = id == nil
            ? [.optionOnScreenOnly, .excludeDesktopElements]
            : [.optionOnScreenAboveWindow, .excludeDesktopElements]
        guard let above = CGWindowListCopyWindowInfo(options, id ?? kCGNullWindowID) as? [[String: Any]] else { return false }
        let ownPID = Int(ProcessInfo.processInfo.processIdentifier)
        passThroughLock.lock()
        let passThrough = passThroughWindows
        passThroughLock.unlock()
        return above.contains { window in
            let own = window[kCGWindowOwnerPID as String] as? Int == ownPID
            if own, let number = window[kCGWindowNumber as String] as? Int, passThrough.contains(number) { return false }
            guard own || (id != nil && window[kCGWindowLayer as String] as? Int == 0),
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let dictionary = window[kCGWindowBounds as String],
                  let frame = CGRect(dictionaryRepresentation: dictionary as! CFDictionary) else { return false }
            return frame.contains(point)
        }
    }

    private static func windowBounds(_ id: CGWindowID) -> CGRect? {
        // A minimized or hidden window still reports its last bounds: only an
        // on-screen window has a place the pointer can be said to be inside.
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let window = list.first, window[kCGWindowIsOnscreen as String] as? Bool == true,
              let dictionary = window[kCGWindowBounds as String] else { return nil }
        return CGRect(dictionaryRepresentation: dictionary as! CFDictionary)
    }

    func start(url: URL, display: CaptureRegion, t0: CMTime) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 120.0, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.poll(display: display, t0: t0) }
        self.timer = timer
        timer.resume()
    }

    /// Stops logging. Events at or after `limit` (seconds since T0, the end of the
    /// video) are discarded, including any written by a poll already under way.
    func stop(at limit: Double? = nil) {
        limitLock.lock()
        self.limit = limit
        limitLock.unlock()
        timer?.cancel()
        queue.sync {
            flush()
            try? handle?.close()
            handle = nil
        }
    }

    private func poll(display: CaptureRegion, t0: CMTime) {
        // Read position, buttons and time together, so everything written below
        // describes the same instant and nothing later can slip in.
        guard let location = CGEvent(source: nil)?.location else { return }
        let buttonsNow = [
            CGEventSource.buttonState(.combinedSessionState, button: .left),
            CGEventSource.buttonState(.combinedSessionState, button: .right),
        ]
        let t = (hostNow() - t0).seconds
        guard t >= 0 else { return }
        limitLock.lock()
        let limit = self.limit
        limitLock.unlock()
        if let limit, t >= limit { return }
        // A captured window can be dragged around or closed, so look up where it is
        // on every poll. If it cannot be found, treat the pointer as outside: the
        // log must never describe activity outside the recorded window.
        var bounds = display.bounds
        var located = true
        if let windowID = display.windowID {
            if let current = Self.windowBounds(windowID) { bounds = current } else { located = false }
        }
        // The picture keeps its original size, so scale by how the window has been resized.
        let scaleX = display.scale * (bounds.width > 0 ? display.bounds.width / bounds.width : 1)
        let scaleY = display.scale * (bounds.height > 0 ? display.bounds.height / bounds.height : 1)
        let x = (location.x - bounds.minX) * scaleX
        let y = (location.y - bounds.minY) * scaleY
        var inside = located && bounds.contains(location)
        // Another window lying over the captured one at this spot receives the
        // pointer, and is not in the video: treat that as outside too.
        // The same goes for CaptureDesktop's own controls (the floating Stop button, its
        // menu), which are never in the video in any capture mode. Only checked
        // when something changed, since it lists windows.
        // Rechecked ~10 times a second regardless, in case a control moved under a still pointer.
        pollCount += 1
        if inside, location != lastRawLocation || buttonsNow != lastButtons || display.windowID != nil || pollCount % 12 == 0 {
            covered = Self.isCovered(display.windowID, at: location)
        }
        lastRawLocation = location
        if inside, covered { inside = false }
        let buttons = buttonsNow
        // Outside the recorded area nothing is logged except one "left" marker, so
        // the log never reveals what the pointer did in other windows or displays.
        guard inside else {
            if lastInside {
                write(t: t, type: "move", x: -1, y: -1, inside: false, button: nil)
                lastInside = false
                lastPoint = CGPoint(x: -1e9, y: -1e9)
            }
            lastButtons = buttons
            return
        }
        // Compare the mapped position, so a window sliding under a still pointer is logged too.
        let mapped = CGPoint(x: (x * 10).rounded() / 10, y: (y * 10).rounded() / 10)
        if mapped != lastPoint || !lastInside {
            write(t: t, type: "move", x: x, y: y, inside: true, button: nil)
            lastPoint = mapped
            lastInside = true
        }
        for (index, name) in ["left", "right"].enumerated() where buttons[index] != lastButtons[index] {
            write(t: t, type: buttons[index] ? "down" : "up", x: x, y: y, inside: true, button: name)
        }
        lastButtons = buttons
        if buffer.count > 16_384 { flush() }
    }

    private func write(t: Double, type: String, x: Double, y: Double, inside: Bool, button: String?) {
        var line = String(format: "{\"t\":%.4f,\"type\":\"%@\",\"x\":%.1f,\"y\":%.1f,\"inside\":%@", t, type, x, y, inside ? "true" : "false")
        if let button { line += ",\"button\":\"\(button)\"" }
        line += "}\n"
        buffer.append(Data(line.utf8))
        events += 1
    }

    private func flush() {
        guard !buffer.isEmpty else { return }
        do {
            try handle?.write(contentsOf: buffer)
        } catch {
            if writeError == nil { writeError = error }
        }
        buffer.removeAll(keepingCapacity: true)
    }
}
