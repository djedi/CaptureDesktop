import AppKit
import SwiftUI

@MainActor
final class Recorder: ObservableObject {
    enum State: Equatable { case idle, countdown(Int), starting, recording, stopping }

    static let shared = Recorder()
    /// Set for `--record-seconds` runs, which never show the recorder window.
    static var headless = false
    @Published private(set) var state: State = .idle
    @Published private(set) var message: String?
    @Published private(set) var lastFolder: URL?
    private var session: RecordingSession?
    private var countdownCancelled = false

    /// The recorder-window flow: hide the window, count down, then record.
    func begin(_ options: RecordingOptions, countdown: Int = 3) async {
        guard state == .idle else { return }
        message = nil
        countdownCancelled = false
        state = .countdown(countdown)
        // Release the camera and microphone previews before the recording takes them.
        await PreviewEngine.shared.stop()
        RecorderWindowController.shared.hide()
        ReviewWindowController.shared.close()
        let screen = CaptureSettings.shared.targetScreen
        for number in stride(from: countdown, to: 0, by: -1) {
            state = .countdown(number)
            CountdownOverlay.shared.show(number, on: screen) { [weak self] in self?.countdownCancelled = true }
            for _ in 0..<10 where !countdownCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if countdownCancelled { break }
        }
        CountdownOverlay.shared.hide()
        state = .idle
        var started = false
        if !countdownCancelled { started = await start(options) }
        if !started { RecorderWindowController.shared.show() }
    }

    @discardableResult
    func start(_ options: RecordingOptions) async -> Bool {
        guard state == .idle else { return false }
        state = .starting
        message = nil
        let session = RecordingSession(options: options)
        do {
            try await session.start()
            self.session = session
            state = .recording
            if !Recorder.headless {
                RecordingHUD.shared.show(on: CaptureSettings.shared.targetScreen) { [weak self] in
                    Task { await self?.stop() }
                }
            }
            return true
        } catch {
            message = error.localizedDescription
            state = .idle
            return false
        }
    }

    func forgetLastFolder() {
        lastFolder = nil
    }

    func cancelCountdown() {
        countdownCancelled = true
    }

    @discardableResult
    func stop() async -> Bool {
        guard state == .recording, let session else { return false }
        state = .stopping
        RecordingHUD.shared.hide()
        defer {
            self.session = nil
            state = .idle
        }
        do {
            let folder = try await session.stop()
            lastFolder = folder
            message = nil
            if !Recorder.headless { ReviewWindowController.shared.show(folder) }
            return true
        } catch {
            if !Recorder.headless { RecorderWindowController.shared.show() }
            lastFolder = session.directory
            message = error.localizedDescription
            return false
        }
    }
}

/// What the Screen source records, as chosen in the menu.
@MainActor
final class CaptureSettings: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case display = "Display", window = "Window", area = "Area"
        var id: String { rawValue }
    }

    static let shared = CaptureSettings()
    @Published var mode: Mode = Mode(rawValue: UserDefaults.standard.string(forKey: "capture.mode") ?? "") ?? .display {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "capture.mode")
            updateOutline()
        }
    }
    @Published var displayID: CGDirectDisplayID = CGMainDisplayID()
    @Published var windows: [WindowItem] = []
    @Published var windowID: CGWindowID?
    @Published var area: ScreenArea? { didSet { updateOutline() } }

    /// `nil` when the current mode has nothing selected yet.
    var target: CaptureTarget? {
        switch mode {
        case .display:
            // The main display is the default; any other choice stays explicit, so
            // recording fails if that display has since been disconnected.
            return .display(displayID == CGMainDisplayID() ? nil : displayID)
        case .window:
            return windowID.map { .window($0) }
        case .area:
            return area.map { .area(display: $0.displayID, rect: $0.rect) }
        }
    }

    /// The screen the capture target is on, for placing the countdown.
    var targetScreen: NSScreen? {
        switch mode {
        case .display: return NSScreen.with(displayID: displayID)
        case .area: return area.flatMap { NSScreen.with(displayID: $0.displayID) }
        case .window: return NSScreen.main
        }
    }

    /// Recording options from the current switches and capture target.
    func makeOptions() -> RecordingOptions {
        var options = RecordingOptions()
        options.screen = SourcePrefs.isOn(SourcePrefs.screenKey)
        options.camera = SourcePrefs.isOn(SourcePrefs.cameraKey)
        options.microphone = SourcePrefs.isOn(SourcePrefs.microphoneKey)
        options.systemAudio = SourcePrefs.isOn(SourcePrefs.systemAudioKey)
        options.nativeResolution = SourcePrefs.isOn(SourcePrefs.nativeResolutionKey)
        if let target { options.target = target }
        return options
    }

    func refreshWindows() async {
        windows = await WindowItem.load().sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        // A window is only ever recorded because the user picked it: if the chosen
        // one has gone, the selection is cleared and nothing is picked in its place.
        if let windowID, !windows.contains(where: { $0.id == windowID }) { self.windowID = nil }
    }

    func usePreset(width: CGFloat, height: CGFloat) {
        let screen = area.flatMap { NSScreen.with(displayID: $0.displayID) } ?? NSScreen.main ?? NSScreen.screens[0]
        area = .centered(width: width, height: height, on: screen)
    }

    private func updateOutline() {
        if mode == .area, let area { AreaOutline.shared.show(area) } else { AreaOutline.shared.hide() }
    }
}

/// Display / Window / Area and resolution controls for the Screen source.
struct ScreenOptionsView: View {
    @EnvironmentObject private var settings: CaptureSettings
    @AppStorage(SourcePrefs.nativeResolutionKey) private var nativeResolution = true

    private static let presets: [(String, CGFloat, CGFloat)] = [
        ("1280 × 720", 1280, 720), ("1920 × 1080", 1920, 1080),
        ("1080 × 1080 (square)", 1080, 1080), ("1080 × 1920 (vertical)", 1080, 1920),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Capture", selection: $settings.mode) {
                ForEach(CaptureSettings.Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch settings.mode {
            case .display:
                let selectionMissing = NSScreen.with(displayID: settings.displayID) == nil
                if NSScreen.screens.count > 1 || selectionMissing {
                    // Also shown with a single display when the chosen one was unplugged,
                    // so there is always a way to pick a connected display.
                    Picker("Display", selection: $settings.displayID) {
                        if selectionMissing { Text("Disconnected: choose a display").tag(settings.displayID) }
                        ForEach(NSScreen.screens, id: \.displayID) { Text($0.localizedName).tag($0.displayID) }
                    }
                } else if let screen = NSScreen.main {
                    Text(sizeLabel(screen.frame.size, scale: screen.backingScaleFactor)).font(.caption).foregroundStyle(.secondary)
                }
            case .window:
                HStack {
                    Picker("Window", selection: $settings.windowID) {
                        Text(settings.windows.isEmpty ? "No windows found" : "Choose a window…").tag(CGWindowID?.none)
                        ForEach(settings.windows) { Text($0.label).lineLimit(1).tag(CGWindowID?.some($0.id)) }
                    }
                    .labelsHidden()
                    Button { Task { await settings.refreshWindows() } } label: { Image(systemName: "arrow.clockwise") }
                        .help("Refresh the window list")
                }
            case .area:
                HStack {
                    Button("Select Area…") {
                        AreaSelector.select { area in if let area { settings.area = area } }
                    }
                    Menu("Preset") {
                        ForEach(Self.presets, id: \.0) { preset in
                            Button(preset.0) { settings.usePreset(width: preset.1, height: preset.2) }
                        }
                    }
                }
                if let area = settings.area {
                    let scale = NSScreen.with(displayID: area.displayID)?.backingScaleFactor ?? 2
                    Text(sizeLabel(area.rect.size, scale: scale)).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("No area selected").font(.caption).foregroundStyle(.secondary)
                }
            }
            Picker("Resolution", selection: $nativeResolution) {
                Text("Native (Retina)").tag(true)
                Text("Standard (1x)").tag(false)
            }
        }
        .task(id: settings.mode) {
            if settings.mode == .window { await settings.refreshWindows() }
        }
    }

    /// Size on screen, plus the video size when it differs.
    private func sizeLabel(_ size: CGSize, scale: CGFloat) -> String {
        let points = "\(Int(size.width)) × \(Int(size.height))"
        guard nativeResolution, scale != 1 else { return "Records at \(points)" }
        return "\(points) on screen, records at \(Int(size.width * scale)) × \(Int(size.height * scale))"
    }
}

/// The menu bar popover: the place to stop a recording, plus quick controls.
struct MenuView: View {
    @EnvironmentObject private var recorder: Recorder
    @EnvironmentObject private var settings: CaptureSettings
    @AppStorage(SourcePrefs.screenKey) private var screen = true
    @AppStorage(SourcePrefs.cameraKey) private var camera = true
    @AppStorage(SourcePrefs.microphoneKey) private var microphone = true
    @AppStorage(SourcePrefs.systemAudioKey) private var systemAudio = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                Toggle("Screen", isOn: $screen)
                if screen { ScreenOptionsView().padding(.leading, 8) }
                Toggle("Camera", isOn: $camera)
                Toggle("Microphone", isOn: $microphone)
                Toggle("System Audio", isOn: $systemAudio)
            }
            .toggleStyle(.switch)
            .disabled(recorder.state != .idle)

            Button(action: toggleRecording) {
                Text(buttonTitle).frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(recorder.state == .starting || recorder.state == .stopping
                      || !(screen || camera || microphone || systemAudio)
                      || (screen && settings.target == nil))

            if let message = recorder.message {
                Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if let folder = recorder.lastFolder, recorder.state == .idle {
                Button("Show Last Recording") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            }
            Divider()
            Button("Open Recorder Window") { RecorderWindowController.shared.show() }
                .disabled(recorder.state != .idle)
            Button("Quit CaptureDesktop") { NSApp.terminate(nil) }
                .disabled(recorder.state != .idle)
        }
        .padding(14)
        .frame(width: 300)
        .onChange(of: [screen, camera, microphone, systemAudio]) { _, _ in PreviewEngine.shared.refresh() }
    }

    private var buttonTitle: String {
        switch recorder.state {
        case .idle: return "Start Recording"
        case .countdown(let number): return "Starting in \(number)… (click to cancel)"
        case .starting: return "Starting…"
        case .recording: return "Stop Recording"
        case .stopping: return "Finishing…"
        }
    }

    private func toggleRecording() {
        Task {
            switch recorder.state {
            case .recording: await recorder.stop()
            case .countdown: recorder.cancelCountdown()
            case .idle: await recorder.begin(settings.makeOptions())
            default: break
            }
        }
    }
}

/// `--record-seconds N` records without the UI and quits, for scripted tests.
/// Also: `--no-screen`, `--no-camera`, `--no-mic`, `--no-system-audio`,
/// `--fps N`, `--output DIR`, `--area X,Y,W,H` (points on the main display),
/// `--window-app NAME` (first window of that app), `--standard-res`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Clicking the Dock icon stops a recording, or brings the recorder window back.
        switch Recorder.shared.state {
        case .idle where !ReviewWindowController.shared.isVisible: RecorderWindowController.shared.show()
        case .recording: Task { await Recorder.shared.stop() }
        default: break
        }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Quitting (Dock menu, Cmd-Q, logout) must not leave a half-written recording:
    /// finish the files first, then let the app go.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let recorder = Recorder.shared
        if recorder.state == .idle { return .terminateNow }
        Task { @MainActor in
            recorder.cancelCountdown()
            // Wait out a start or stop that is already under way, then stop a live recording.
            while recorder.state != .idle {
                if recorder.state == .recording { await recorder.stop() } else {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        // Every flag that takes a value must have one. A flag silently ignored could
        // mean recording more than was asked for (for example the whole screen
        // when a window or area was intended).
        let valueFlags = ["--record-seconds", "--ui-test-seconds", "--fps", "--output", "--area", "--window-app",
                          "--review", "--resolve-project", "--project-name", "--render-cursor", "--process-camera"]
        let switches = ["--no-screen", "--no-camera", "--no-mic", "--no-system-audio", "--standard-res",
                        "--show-outline", "--circle", "--keep-background"]
        for (index, argument) in args.enumerated().dropFirst() where argument.hasPrefix("--") {
            guard valueFlags.contains(argument) || switches.contains(argument) else {
                log("unknown option \(argument)")
                exit(2)
            }
            guard args.filter({ $0 == argument }).count == 1 else {
                log("\(argument) was given more than once")
                exit(2)
            }
            if valueFlags.contains(argument) {
                let text = index + 1 < args.count ? args[index + 1] : ""
                guard !text.isEmpty, !text.hasPrefix("--") else {
                    log("\(argument) needs a value")
                    exit(2)
                }
            }
        }
        // One capture target at most, and no target at all when the screen is not recorded.
        let targets = ["--area", "--window-app"].filter(args.contains)
        if targets.count > 1 || (!targets.isEmpty && args.contains("--no-screen")) {
            log("choose one of --area, --window-app or --no-screen, not a combination")
            exit(2)
        }
        /// A duration flag, rejected unless it is a sensible number of seconds.
        func seconds(_ flag: String) -> Double? {
            guard args.contains(flag) else { return nil }
            guard let text = value(flag), let number = Double(text), number.isFinite, number > 0, number <= 86_400 else {
                log("\(flag) needs a number of seconds between 0 and 86400, got \(value(flag) ?? "nothing")")
                exit(2)
            }
            return number
        }
        // Validate every scripted number up front, whichever mode ends up running.
        let recordSeconds = seconds("--record-seconds"), uiTestSeconds = seconds("--ui-test-seconds")
        var scriptedFPS: Int32?
        if args.contains("--fps") {
            guard let fps = value("--fps").flatMap({ Int32($0) }), (1...120).contains(fps) else {
                log("--fps needs a whole number between 1 and 120, got \(value("--fps") ?? "nothing")")
                exit(2)
            }
            scriptedFPS = fps
        }
        // `--review FOLDER` opens the review window for an existing recording.
        if let folder = value("--review") {
            ReviewWindowController.shared.show(URL(fileURLWithPath: folder, isDirectory: true))
            return
        }
        // `--process-camera FOLDER [--circle] [--keep-background]` writes the transparent camera copy and quits.
        if let folder = value("--process-camera") {
            Recorder.headless = true
            Task { @MainActor in
                let url = URL(fileURLWithPath: folder, isDirectory: true)
                var settings = CameraLayoutSettings()
                settings.removeBackground = !args.contains("--keep-background")
                settings.shape = args.contains("--circle") ? .circle : .rectangle
                do {
                    let started = Date()
                    try await CameraProcessor.render(source: url.appendingPathComponent("camera.mov"),
                                                     to: url.appendingPathComponent(CameraProcessor.fileName(for: settings)),
                                                     settings: settings) { _ in }
                    log("process camera: done in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
                    exit(0)
                } catch {
                    log("process camera failed: \(error.localizedDescription)")
                    exit(1)
                }
            }
            return
        }
        // `--render-cursor FOLDER` writes the cursor effects layer for a recording and quits.
        if let folder = value("--render-cursor") {
            Recorder.headless = true
            Task { @MainActor in
                let url = URL(fileURLWithPath: folder, isDirectory: true)
                guard let track = CursorTrack.load(url) else {
                    log("render cursor: no screen video or cursor log in \(folder)")
                    exit(1)
                }
                do {
                    let started = Date()
                    let settings = CursorEffectSettings.load()
                    try await CursorEffectRenderer.render(track: track, settings: settings,
                                                          to: url.appendingPathComponent(CursorEffectRenderer.fileName(for: settings))) { _ in }
                    log("render cursor: \(track.frames) frames, \(track.moves.count) moves, \(track.clicks.count) clicks in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
                    exit(0)
                } catch {
                    log("render cursor failed: \(error.localizedDescription)")
                    exit(1)
                }
            }
            return
        }
        // `--resolve-project FOLDER [--project-name NAME]` builds a Resolve project from a recording and quits.
        if let folder = value("--resolve-project") {
            Recorder.headless = true
            Task { @MainActor in
                do {
                    let url = URL(fileURLWithPath: folder, isDirectory: true)
                    let name = value("--project-name") ?? "CaptureDesktop \(url.lastPathComponent)"
                    // Renders the layers with the saved settings, exactly as the review window does.
                    let export = ProjectExport(folder: url, effects: .load(), camera: .load()) { _ in }
                    let options = try await export.resolveOptions()
                    log("resolve project created: \(try await ResolveBridge.createProject(from: url, name: name, options: options))")
                    exit(0)
                } catch {
                    log("resolve project failed: \(error.localizedDescription)")
                    exit(1)
                }
            }
            return
        }
        guard let seconds = recordSeconds else {
            RecorderWindowController.shared.show()
            // `--ui-test-seconds N` drives the real window flow: countdown, record N seconds, stop, quit.
            if let testSeconds = uiTestSeconds {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    var options = CaptureSettings.shared.makeOptions()
                    if let output = value("--output") { options.outputRoot = URL(fileURLWithPath: output, isDirectory: true) }
                    await Recorder.shared.begin(options)
                    guard Recorder.shared.state == .recording else {
                        log("ui test: recording did not start: \(Recorder.shared.message ?? "unknown")")
                        exit(1)
                    }
                    log("ui test: recording")
                    try? await Task.sleep(nanoseconds: UInt64(testSeconds * 1_000_000_000))
                    let ok = await Recorder.shared.stop()
                    log("ui test: stopped ok=\(ok) folder=\(Recorder.shared.lastFolder?.path ?? "-")")
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    exit(ok ? 0 : 1)
                }
            }
            return
        }
        Recorder.headless = true

        var options = RecordingOptions()
        options.screen = !args.contains("--no-screen")
        options.camera = !args.contains("--no-camera")
        options.microphone = !args.contains("--no-mic")
        options.systemAudio = !args.contains("--no-system-audio")
        if let scriptedFPS { options.fps = scriptedFPS }
        if let output = value("--output") { options.outputRoot = URL(fileURLWithPath: output, isDirectory: true) }
        options.nativeResolution = !args.contains("--standard-res")
        if args.contains("--area") {
            // A bad area must never fall back to recording the whole screen.
            let fields = value("--area")?.split(separator: ",", omittingEmptySubsequences: false) ?? []
            let parts = fields.compactMap { Double($0) }
            guard fields.count == 4, parts.count == 4, parts.allSatisfy(\.isFinite),
                  parts[0] >= 0, parts[1] >= 0, parts[2] >= 16, parts[3] >= 16 else {
                log("--area needs X,Y,W,H in points (W and H at least 16), got \(value("--area") ?? "nothing")")
                exit(2)
            }
            let area = ScreenArea(displayID: CGMainDisplayID(), rect: CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3]))
            options.target = .area(display: area.displayID, rect: area.rect)
            if args.contains("--show-outline") { Task { @MainActor in AreaOutline.shared.show(area) } }
        }
        let windowApp = value("--window-app")

        Task { @MainActor in
            let recorder = Recorder.shared
            var options = options
            if let windowApp {
                guard let window = await WindowItem.load().first(where: { $0.app == windowApp }) else {
                    log("no window found for app \(windowApp)")
                    exit(1)
                }
                options.target = .window(window.id)
            }
            guard await recorder.start(options) else {
                log("start failed: \(recorder.message ?? "unknown error")")
                exit(1)
            }
            log("recording for \(seconds)s")
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            let ok = await recorder.stop()
            if let folder = recorder.lastFolder { log("saved \(folder.path)") }
            if !ok { log("stop failed: \(recorder.message ?? "unknown error")") }
            exit(ok ? 0 : 1)
        }
    }
}

@main
struct CaptureDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var recorder = Recorder.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(recorder).environmentObject(CaptureSettings.shared)
        } label: {
            Image(systemName: recorder.state == .recording ? "stop.circle.fill" : "record.circle")
        }
        .menuBarExtraStyle(.window)
    }
}
