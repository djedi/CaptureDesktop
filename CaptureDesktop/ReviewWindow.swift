import AppKit
import AVFoundation
import AVKit
import SwiftUI

/// What a finished recording folder contains, read back from disk.
struct RecordingSummary {
    struct File: Identifiable {
        let url: URL
        let detail: String
        let bytes: Int64
        var id: URL { url }
    }

    let folder: URL
    let files: [File]
    let seconds: Double
    let thumbnail: CGImage?

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    var durationText: String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func load(_ folder: URL) async -> RecordingSummary {
        let json = (try? Data(contentsOf: folder.appendingPathComponent("session.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let tracks = json["tracks"] as? [String: [String: Any]] ?? [:]
        let capture = json["capture"] as? [String: Any]
        let seconds = tracks.values.compactMap { $0["seconds"] as? Double }.max() ?? 0

        var audioParts: [String] = []
        if tracks["systemAudio"] != nil { audioParts.append("system audio") }
        if tracks["microphone"] != nil { audioParts.append("microphone") }
        var screenParts: [String] = []
        if let width = capture?["pixelWidth"] as? Int, let height = capture?["pixelHeight"] as? Int, tracks["screen"] != nil {
            screenParts.append("Screen \(width) × \(height)")
        }
        let details: [String: String] = [
            "screen.mov": (screenParts + audioParts).joined(separator: ", "),
            "audio.mov": audioParts.joined(separator: ", ").capitalizedFirst,
            "camera.mov": "Camera" + ((json["camera"] as? String).map { " (\($0))" } ?? ""),
            "cursor.jsonl": "Mouse positions and clicks",
            "session.json": "Capture details",
        ]
        // Rendered layers have one file per look, e.g. cursor-effects-1a2b3c4d.mov.
        let present = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        let cutouts = present.filter { $0.hasPrefix(CameraProcessor.filePrefix) && $0.hasSuffix(".mov") }
        let cursorLayers = present.filter { $0.hasPrefix(CursorEffectRenderer.filePrefix) && $0.hasSuffix(".mov") }
        let names = ["screen.mov", "audio.mov", "camera.mov"] + cutouts + cursorLayers + ["cursor.jsonl", "session.json"]
        let files: [File] = names.compactMap { name in
            let url = folder.appendingPathComponent(name)
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return nil }
            let detail = details[name]
                ?? (cutouts.contains(name) ? "Transparent camera (background removed or shaped)" : "Transparent cursor highlight layer")
            return File(url: url, detail: detail, bytes: Int64(size))
        }

        var thumbnail: CGImage?
        if let video = files.first(where: { $0.url.lastPathComponent == "screen.mov" && tracks["screen"] != nil })
            ?? files.first(where: { $0.url.lastPathComponent == "camera.mov" }) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video.url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 960, height: 960)
            let time = CMTime(seconds: min(1, seconds / 2), preferredTimescale: 600)
            thumbnail = try? await generator.image(at: time).image
        }
        return RecordingSummary(folder: folder, files: files, seconds: seconds, thumbnail: thumbnail)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Runs the bundled script that builds a DaVinci Resolve project from a recording.
enum ResolveBridge {
    static let bundleIDs = ["com.blackmagic-design.DaVinciResolve", "com.blackmagic-design.DaVinciResolveLite"]
    static let scriptingAPI = "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting"

    static var appURL: URL? {
        bundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    static var isInstalled: Bool { appURL != nil }

    /// Returns the name of the project that was created.
    static func createProject(from folder: URL, name: String, options: [String: Any] = [:]) async throws -> String {
        let optionsJSON = (try? JSONSerialization.data(withJSONObject: options)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        guard let appURL else { throw RecorderError("DaVinci Resolve is not installed.") }
        guard let script = Bundle.main.url(forResource: "resolve_project", withExtension: "py") else {
            throw RecorderError("The Resolve script is missing from the app.")
        }
        let library = appURL.appendingPathComponent("Contents/Libraries/Fusion/fusionscript.so").path
        guard FileManager.default.fileExists(atPath: library), FileManager.default.fileExists(atPath: scriptingAPI) else {
            throw RecorderError("DaVinci Resolve's scripting files were not found.")
        }
        let pythons = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
        guard !pythons.isEmpty else { throw RecorderError("Python 3 is needed to talk to DaVinci Resolve, and none was found.") }

        // Start Resolve if needed; the script waits for it to be ready.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)

        var lastError = "DaVinci Resolve did not respond."
        for python in pythons {
            let result = try await run(python: python, script: script, folder: folder, name: name, options: optionsJSON, library: library)
            if result.ok, let project = result.project { return project }
            lastError = result.error ?? lastError
            // Exit code 3: this Python cannot load Resolve's module, so try the next one.
            if result.exitCode != 3 { break }
        }
        throw RecorderError(lastError)
    }

    private struct Result {
        var ok = false
        var project: String?
        var error: String?
        var exitCode: Int32 = 0
    }

    private static func run(python: String, script: URL, folder: URL, name: String, options: String, library: String) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = [script.path, folder.path, name, options]
            var environment = ProcessInfo.processInfo.environment
            environment["RESOLVE_SCRIPT_API"] = scriptingAPI
            environment["RESOLVE_SCRIPT_LIB"] = library
            process.environment = environment
            let output = Pipe(), errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            do { try process.run() } catch {
                continuation.resume(throwing: error)
                return
            }
            // Read both pipes to the end on their own threads while the script runs
            // (a full pipe would block it forever), and parse only once both are done.
            let readers = DispatchGroup()
            var outputData = Data(), errorData = Data()
            DispatchQueue.global(qos: .utility).async(group: readers) {
                outputData = output.fileHandleForReading.readDataToEndOfFile()
            }
            DispatchQueue.global(qos: .utility).async(group: readers) {
                errorData = errors.fileHandleForReading.readDataToEndOfFile()
            }
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                readers.wait()
                let text = String(data: outputData, encoding: .utf8) ?? ""
                let errorText = String(data: errorData, encoding: .utf8) ?? ""
                var result = Result(exitCode: process.terminationStatus)
                if let line = text.split(separator: "\n").last,
                   let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
                    result.ok = object["ok"] as? Bool ?? false
                    result.project = object["project"] as? String
                    result.error = object["error"] as? String
                } else {
                    let detail = errorText.split(separator: "\n").last.map { ": \($0)" } ?? ""
                    result.error = "The Resolve script ended unexpectedly (exit code \(process.terminationStatus))\(detail)"
                }
                continuation.resume(returning: result)
            }
        }
    }
}

/// Renders the layers a recording needs for one set of settings and describes
/// them to the Resolve script. Shared by the review window and the scripted
/// `--resolve-project` flag, so both always render with the settings they pass on.
struct ProjectExport {
    let folder: URL
    let effects: CursorEffectSettings
    let camera: CameraLayoutSettings
    /// Receives progress text; may be called from any thread.
    let status: @Sendable (String) -> Void

    /// Makes sure the cursor layer for these settings exists, rendering it if needed.
    /// Returns its file name, or nil when effects are off or the recording has no
    /// screen video or mouse log.
    func cursorLayer() async throws -> String? {
        guard effects.isActive, let track = CursorTrack.load(folder) else { return nil }
        let name = CursorEffectRenderer.fileName(for: effects)
        let url = folder.appendingPathComponent(name)
        // A finished file for exactly these settings is reused, never rewritten.
        if FileManager.default.fileExists(atPath: url.path) { return name }
        status("Rendering cursor effects…")
        try await Task.detached(priority: .userInitiated) { [effects, status] in
            try await CursorEffectRenderer.render(track: track, settings: effects, to: url) { fraction in
                status("Rendering cursor effects… \(Int(fraction * 100))%")
            }
        }.value
        return name
    }

    /// Makes sure the transparent camera copy for this look exists when one is needed.
    /// Returns the camera file the editor should use, or nil when there is no camera recording.
    func cameraFile() async throws -> String? {
        let source = folder.appendingPathComponent("camera.mov")
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        guard camera.needsProcessing else { return "camera.mov" }
        let name = CameraProcessor.fileName(for: camera)
        let url = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return name }
        let label = camera.removeBackground ? "Removing camera background…" : "Shaping camera…"
        status(label)
        try await Task.detached(priority: .userInitiated) { [camera, status] in
            try await CameraProcessor.render(source: source, to: url, settings: camera) { fraction in
                status("\(label) \(Int(fraction * 100))%")
            }
        }.value
        return name
    }

    /// Renders what is needed and returns the options for `ResolveBridge.createProject`.
    func resolveOptions() async throws -> [String: Any] {
        // Always say which cursor file to use (or none), so the script never picks one up by itself.
        var options: [String: Any] = ["cursorEffectsFile": try await cursorLayer() ?? ""]
        if let file = try await cameraFile() { options["camera"] = camera.resolveOptions(file: file) }
        return options
    }
}

/// The window shown after a recording finishes.
@MainActor
final class ReviewWindowController: NSObject, NSWindowDelegate {
    static let shared = ReviewWindowController()
    private var window: NSWindow?
    private let model = ReviewModel()

    func show(_ folder: URL) {
        model.load(folder)
        let window = self.window ?? makeWindow()
        self.window = window
        window.title = "Recording \(folder.lastPathComponent)"
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        model.player?.pause()
        window?.orderOut(nil)
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func windowWillClose(_ notification: Notification) {
        model.player?.pause()
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: ReviewView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }
}

@MainActor
final class ReviewModel: ObservableObject {
    enum Activity: Equatable { case idle, working(String), done(String), failed(String) }

    @Published private(set) var summary: RecordingSummary?
    @Published private(set) var activity: Activity = .idle
    @Published private(set) var player: AVPlayer?
    /// The mouse log, when the recording has a screen video and cursor data.
    @Published private(set) var cursorTrack: CursorTrack?
    @Published var effects = CursorEffectSettings.load() { didSet { effects.save() } }
    @Published var camera = CameraLayoutSettings.load() { didSet { camera.save() } }
    /// True when the recording has a camera file.
    /// Size of the screen picture in points, when the recording has screen video.
    @Published private(set) var screenSize: CGSize?
    @Published private(set) var hasCamera = false
    /// Camera width / height, for the layout preview.
    @Published private(set) var cameraAspect: CGFloat = 16.0 / 9.0
    private(set) var folder: URL?
    /// Counts loads of the window; see `run`.
    private var generation = 0

    var isWorking: Bool { if case .working = activity { return true } else { return false } }

    func load(_ folder: URL) {
        generation += 1
        let started = generation
        self.folder = folder
        summary = nil
        activity = .idle
        player?.pause()
        player = nil
        cursorTrack = CursorTrack.load(folder)
        screenSize = CursorTrack.pictureSize(folder)
        let screen = folder.appendingPathComponent("screen.mov"), cameraURL = folder.appendingPathComponent("camera.mov")
        hasCamera = FileManager.default.fileExists(atPath: cameraURL.path)
        // screen.mov holds video only when the Screen source was on (otherwise there is no such file).
        if FileManager.default.fileExists(atPath: screen.path) {
            player = AVPlayer(url: screen)
        } else {
            // With the Screen source off, sound is recorded to audio.mov beside the camera file.
            let audio = folder.appendingPathComponent("audio.mov")
            let hasAudio = FileManager.default.fileExists(atPath: audio.path)
            if hasCamera && hasAudio {
                // The player appears once picture and sound are combined, so playback never restarts under the user.
                Task {
                    let item = await Self.combinedItem(video: cameraURL, audio: audio) ?? AVPlayerItem(url: cameraURL)
                    if generation == started, player == nil { player = AVPlayer(playerItem: item) }
                }
            } else if hasCamera {
                player = AVPlayer(url: cameraURL)
            } else if hasAudio {
                player = AVPlayer(url: audio)
            }
        }
        Task {
            let loaded = await RecordingSummary.load(folder)
            if generation == started { summary = loaded }
            if hasCamera, let track = try? await AVURLAsset(url: cameraURL).loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize), size.height > 0, generation == started {
                cameraAspect = size.width / size.height
            }
        }
    }

    /// One player item with the camera picture and every track of the separate audio file.
    private static func combinedItem(video: URL, audio: URL) async -> AVPlayerItem? {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video), audioAsset = AVURLAsset(url: audio)
        guard let duration = try? await videoAsset.load(.duration),
              let videoTrack = try? await videoAsset.loadTracks(withMediaType: .video).first,
              let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              (try? target.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: videoTrack, at: .zero)) != nil else { return nil }
        for track in (try? await audioAsset.loadTracks(withMediaType: .audio)) ?? [] {
            guard let range = try? await track.load(.timeRange) else { continue }
            let audioTarget = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            try? audioTarget?.insertTimeRange(range, of: track, at: .zero)
        }
        return AVPlayerItem(asset: composition)
    }

    func showInFinder() {
        guard let folder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    /// Runs one export for the recording shown now, with the settings as they are at this moment.
    /// The generation ties the operation to this particular load of the window, so
    /// an operation left over from an earlier load (even of the same recording)
    /// can never write its progress or result over the current one.
    private func run(_ operation: @escaping (URL, ProjectExport) async throws -> String) {
        guard let folder, !isWorking else { return }
        player?.pause()
        let started = generation
        let export = ProjectExport(folder: folder, effects: effects, camera: camera) { [weak self] text in
            Task { @MainActor [weak self] in
                guard let self, self.generation == started, self.isWorking else { return }
                self.activity = .working(text)
            }
        }
        activity = .working("Working…")
        Task {
            let outcome: Activity
            do { outcome = .done(try await operation(folder, export)) } catch { outcome = .failed(error.localizedDescription) }
            guard generation == started else { return }
            activity = outcome
            let loaded = await RecordingSummary.load(folder)
            if generation == started { summary = loaded }
        }
    }

    func exportCameraCutout() {
        run { _, export in
            guard let name = try await export.cameraFile() else { throw RecorderError("This recording has no camera video.") }
            return "Saved \(name)"
        }
    }

    func exportCursorLayer() {
        run { _, export in
            guard let name = try await export.cursorLayer() else { throw RecorderError("There are no cursor effects to export.") }
            return "Saved \(name)"
        }
    }

    func createResolveProject() {
        run { folder, export in
            let options = try await export.resolveOptions()
            export.status("Starting Resolve and importing…")
            let project = try await ResolveBridge.createProject(
                from: folder, name: "CaptureDesktop \(folder.lastPathComponent)", options: options)
            return "Created Resolve project \"\(project)\""
        }
    }

    func newRecording() {
        ReviewWindowController.shared.close()
        RecorderWindowController.shared.show()
    }

    func moveToTrash() {
        guard let folder else { return }
        let alert = NSAlert()
        alert.messageText = "Move this recording to the Trash?"
        alert.informativeText = folder.lastPathComponent
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        player?.pause()
        player = nil
        do {
            try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
            Recorder.shared.forgetLastFolder()
            newRecording()
        } catch {
            activity = .failed("Could not move the recording to the Trash: \(error.localizedDescription)")
        }
    }
}

/// Plays the recording with the cursor effects drawn live on top.
private struct EffectsPlayerView: NSViewRepresentable {
    let player: AVPlayer
    let track: CursorTrack?
    let settings: CursorEffectSettings
    /// Size of the screen picture in points; nil when the player shows something else.
    var pictureSize: CGSize?
    /// Set when the player shows the screen and the recording has a camera.
    var cameraLayout: CameraLayoutSettings?
    var cameraAspect: CGFloat = 16.0 / 9.0

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        let overlay = CursorOverlayView(frame: view.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.playerView = view
        view.contentOverlayView?.addSubview(overlay)
        overlay.start()
        context.coordinator.overlay = overlay
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
        context.coordinator.overlay?.track = track
        context.coordinator.overlay?.settings = settings
        context.coordinator.overlay?.pictureSize = pictureSize
        context.coordinator.overlay?.cameraLayout = cameraLayout
        context.coordinator.overlay?.cameraAspect = cameraAspect
        context.coordinator.overlay?.needsDisplay = true
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        coordinator.overlay?.stop()
        view.player?.pause()
        view.player = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var overlay: CursorOverlayView?
    }
}

final class CursorOverlayView: NSView {
    weak var playerView: AVPlayerView?
    var track: CursorTrack?
    var settings = CursorEffectSettings()
    var pictureSize: CGSize?
    var cameraLayout: CameraLayoutSettings?
    var cameraAspect: CGFloat = 16.0 / 9.0
    private var timer: Timer?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func start() {
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.needsDisplay = true }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        // The camera placeholder only needs the picture size; cursor effects need the mouse log too.
        guard let size = track?.size ?? pictureSize, let playerView, let player = playerView.player,
              let context = NSGraphicsContext.current?.cgContext else { return }
        let video = playerView.videoBounds
        guard video.width > 1, size.width > 1, size.height > 1 else { return }
        context.saveGState()
        context.clip(to: video)
        // The picture is centred, so its rectangle is the same in flipped coordinates.
        context.translateBy(x: video.minX, y: video.minY)
        context.scaleBy(x: video.width / size.width, y: video.height / size.height)
        let time = player.currentTime().seconds
        if let track, settings.isActive, time.isFinite {
            CursorEffectPainter.draw(in: context, track: track, time: time, settings: settings)
        }
        if let cameraLayout { drawCameraPlaceholder(cameraLayout, in: context, size: size) }
        context.restoreGState()
    }

    /// Shows where the camera will sit in the editor project.
    private func drawCameraPlaceholder(_ layout: CameraLayoutSettings, in context: CGContext, size: CGSize) {
        let frame = layout.frame(in: size, cameraAspect: cameraAspect)
        let path = layout.shape == .circle
            ? CGPath(ellipseIn: frame, transform: nil)
            : CGPath(roundedRect: frame, cornerWidth: size.width * 0.004, cornerHeight: size.width * 0.004, transform: nil)
        context.addPath(path)
        context.setFillColor(CGColor(srgbRed: 0.24, green: 0.84, blue: 0.78, alpha: layout.removeBackground ? 0.12 : 0.3))
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(CGColor(srgbRed: 0.24, green: 0.84, blue: 0.78, alpha: 0.95))
        context.setLineWidth(size.width * 0.003)
        if layout.removeBackground { context.setLineDash(phase: 0, lengths: [size.width * 0.01, size.width * 0.007]) }
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [])
        let label = NSAttributedString(string: "Camera", attributes: [
            .font: NSFont.systemFont(ofSize: max(10, frame.width * 0.11), weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let labelSize = label.size()
        label.draw(at: CGPoint(x: frame.midX - labelSize.width / 2, y: frame.midY - labelSize.height / 2))
    }
}

private struct ReviewView: View {
    @ObservedObject var model: ReviewModel

    private let background = Color(red: 0.075, green: 0.082, blue: 0.102)
    private let card = Color(red: 0.118, green: 0.129, blue: 0.157)
    private let well = Color(red: 0.047, green: 0.051, blue: 0.067)
    private let stageWidth: CGFloat = 640

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    well
                    if let player = model.player {
                        EffectsPlayerView(player: player, track: model.cursorTrack, settings: model.effects,
                                          pictureSize: model.screenSize,
                                          cameraLayout: model.hasCamera && model.screenSize != nil ? model.camera : nil,
                                          cameraAspect: model.cameraAspect)
                    } else if let image = model.summary?.thumbnail {
                        Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    } else if model.summary == nil {
                        ProgressView()
                    } else {
                        Image(systemName: "waveform").font(.system(size: 40)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: stageWidth, height: stageWidth * 10 / 16)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                if let summary = model.summary {
                    HStack(spacing: 14) {
                        Label(summary.durationText, systemImage: "clock")
                        Label(ByteCountFormatter.string(fromByteCount: summary.totalBytes, countStyle: .file), systemImage: "internaldrive")
                    }
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(summary.files) { file in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(file.url.lastPathComponent).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white)
                                    .frame(width: 210, alignment: .leading)
                                Text(file.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(ByteCountFormatter.string(fromByteCount: file.bytes, countStyle: .file))
                                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(12)
                    .frame(width: stageWidth)
                    .background(RoundedRectangle(cornerRadius: 8).fill(card))
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                if model.cursorTrack != nil {
                    heading("Cursor effects")
                    effectsCard
                }
                if model.hasCamera {
                    heading("Camera")
                    cameraCard
                }
                heading("What next")
                ActionButton(title: "Create DaVinci Resolve Project",
                             subtitle: ResolveBridge.isInstalled ? "Screen, cursor effects and camera on a timeline, using the settings above" : "DaVinci Resolve is not installed",
                             symbol: "film.stack", busy: model.isWorking, action: model.createResolveProject)
                    .disabled(!ResolveBridge.isInstalled || model.isWorking)
                if model.cursorTrack != nil {
                    ActionButton(title: "Export Cursor Effects Layer", subtitle: "Transparent video for any editor",
                                 symbol: "cursorarrow.rays", action: model.exportCursorLayer)
                        .disabled(model.isWorking || !model.effects.isActive)
                }
                if model.hasCamera && model.camera.needsProcessing {
                    ActionButton(title: "Export Camera Cutout", subtitle: "Transparent camera video for any editor",
                                 symbol: "person.crop.rectangle", action: model.exportCameraCutout)
                        .disabled(model.isWorking)
                }
                ActionButton(title: "Show in Finder", subtitle: "Open the recording folder", symbol: "folder", action: model.showInFinder)
                status
                Divider().padding(.vertical, 2)
                ActionButton(title: "New Recording", subtitle: "Back to the recorder", symbol: "record.circle", action: model.newRecording)
                    .disabled(model.isWorking)
                ActionButton(title: "Move to Trash", subtitle: "Delete this recording", symbol: "trash", action: model.moveToTrash)
                    .disabled(model.isWorking)
            }
            .frame(width: 300)
        }
        .padding(18)
        .background(background)
    }

    private func heading(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 11, weight: .semibold)).kerning(1.2).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var status: some View {
        switch model.activity {
        case .idle:
            EmptyView()
        case .working(let text):
            Text(text).font(.caption).foregroundStyle(.secondary)
        case .done(let text):
            Label(text, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let text):
            Text(text).font(.caption).foregroundStyle(Color(red: 0.93, green: 0.27, blue: 0.27))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func colorBinding(_ keyPath: WritableKeyPath<CursorEffectSettings, RGBA>) -> Binding<Color> {
        Binding(get: { model.effects[keyPath: keyPath].color }, set: { model.effects[keyPath: keyPath] = RGBA($0) })
    }

    private var effectsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("Highlight cursor", isOn: $model.effects.highlight)
                Spacer()
                ColorPicker("", selection: colorBinding(\.highlightColor), supportsOpacity: false).labelsHidden()
                    .disabled(!model.effects.highlight)
            }
            Group {
                slider("Size", value: $model.effects.highlightRadius, range: 12...80, text: "\(Int(model.effects.highlightRadius))")
                slider("Opacity", value: $model.effects.highlightOpacity, range: 0.1...0.9, text: "\(Int(model.effects.highlightOpacity * 100))%")
                    .disabled(!model.effects.highlight)
            }
            Divider()
            HStack {
                Toggle("Click ripples", isOn: $model.effects.clicks)
                Spacer()
                ColorPicker("", selection: colorBinding(\.leftClickColor), supportsOpacity: false).labelsHidden().help("Left click colour")
                ColorPicker("", selection: colorBinding(\.rightClickColor), supportsOpacity: false).labelsHidden().help("Right click colour")
            }
            Text("Play the recording to preview. Effects are rendered as a separate layer; the screen video is not changed.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(.switch).controlSize(.small)
        .foregroundStyle(.white)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(card))
        .disabled(model.isWorking)
    }

    private var cameraCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Remove background", isOn: $model.camera.removeBackground)
            HStack {
                Text("Shape").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
                Picker("", selection: $model.camera.shape) {
                    ForEach(CameraLayoutSettings.Shape.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            slider("Size", value: $model.camera.size, range: 0.1...0.5, text: "\(Int(model.camera.size * 100))%")
            HStack {
                Text("Corner").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
                Picker("", selection: $model.camera.corner) {
                    ForEach(CameraLayoutSettings.Corner.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
            }
        }
        .toggleStyle(.switch).controlSize(.small)
        .foregroundStyle(.white)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(card))
        .disabled(model.isWorking)
    }

    private func slider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, text: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
            Slider(value: value, in: range)
            Text(text).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
        }
    }
}

private struct ActionButton: View {
    let title: String
    let subtitle: String
    let symbol: String
    var busy = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    if busy { ProgressView().controlSize(.small) } else { Image(systemName: symbol).font(.system(size: 16)) }
                }
                .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(red: 0.118, green: 0.129, blue: 0.157)))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
    }
}
