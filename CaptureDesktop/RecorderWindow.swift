import AppKit
import AVFoundation
import SwiftUI

/// The main recorder window: one card per source and a large record button.
@MainActor
final class RecorderWindowController: NSObject, NSWindowDelegate {
    static let shared = RecorderWindowController()
    private var window: NSWindow?

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        PreviewEngine.shared.start()
    }

    /// Hide without quitting, e.g. while recording.
    func hide() {
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        Task {
            // The window may have been reopened before this runs: only stop the
            // previews if it is really gone, and bring them back if it returned meanwhile.
            guard window?.isVisible != true else { return }
            await PreviewEngine.shared.stop()
            if window?.isVisible == true, Recorder.shared.state == .idle { PreviewEngine.shared.start() }
        }
    }

    private func makeWindow() -> NSWindow {
        let view = RecorderView()
            .environmentObject(Recorder.shared)
            .environmentObject(CaptureSettings.shared)
            .environmentObject(PreviewEngine.shared)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "CaptureDesktop Recorder"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }
}

private enum Palette {
    static let window = Color(red: 0.075, green: 0.082, blue: 0.102)
    static let card = Color(red: 0.118, green: 0.129, blue: 0.157)
    static let well = Color(red: 0.047, green: 0.051, blue: 0.067)
    static let record = Color(red: 0.93, green: 0.27, blue: 0.27)
    static let microphone = Color(red: 0.24, green: 0.84, blue: 0.78)
    static let systemAudio = Color(red: 0.62, green: 0.55, blue: 1.0)
}

struct RecorderView: View {
    @EnvironmentObject private var recorder: Recorder
    @EnvironmentObject private var settings: CaptureSettings
    @EnvironmentObject private var previews: PreviewEngine
    @AppStorage(SourcePrefs.screenKey) private var screen = true
    @AppStorage(SourcePrefs.cameraKey) private var camera = true
    @AppStorage(SourcePrefs.microphoneKey) private var microphone = true
    @AppStorage(SourcePrefs.systemAudioKey) private var systemAudio = true

    private let columnWidth: CGFloat = 400

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Video") {
                HStack(alignment: .top, spacing: 14) {
                    VideoCard(title: "Screen", symbol: "display", isOn: $screen, width: columnWidth) {
                        if !previews.screenPermission {
                            CardHint(symbol: "lock.display", text: "Allow Screen Recording in System Settings, then relaunch")
                        } else if let image = previews.screenImage {
                            Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        } else {
                            CardHint(symbol: "display", text: settings.target == nil ? "Nothing selected" : "")
                        }
                    } footer: {
                        ScreenOptionsView()
                    }
                    VideoCard(title: AVCaptureDevice.default(for: .video)?.localizedName ?? "Camera",
                              symbol: "web.camera", isOn: $camera, width: columnWidth) {
                        CameraPreviewView(session: previews.devices.session)
                    }
                }
            }
            section("Audio") {
                HStack(alignment: .top, spacing: 14) {
                    AudioCard(title: AVCaptureDevice.default(for: .audio)?.localizedName ?? "Microphone",
                              symbol: "mic.fill", tint: Palette.microphone, isOn: $microphone,
                              history: previews.microphoneHistory, width: columnWidth)
                    AudioCard(title: "System Audio", symbol: "speaker.wave.2.fill", tint: Palette.systemAudio,
                              isOn: $systemAudio, history: previews.systemHistory, width: columnWidth)
                }
            }
            footer
        }
        .padding(18)
        .background(Palette.window)
        .onChange(of: [screen, camera, microphone, systemAudio]) { _, _ in previews.refresh() }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold)).kerning(1.2)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private var canRecord: Bool {
        recorder.state == .idle && (screen || camera || microphone || systemAudio) && (!screen || settings.target != nil)
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                if let message = recorder.message {
                    Text(message).font(.callout).foregroundStyle(Palette.record).fixedSize(horizontal: false, vertical: true)
                } else if let folder = recorder.lastFolder {
                    HStack(spacing: 8) {
                        Text("Last recording: \(folder.lastPathComponent)").font(.callout).foregroundStyle(.secondary)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                            .buttonStyle(.link)
                    }
                } else {
                    Text("Recordings are saved to Movies/CaptureDesktop").font(.callout).foregroundStyle(.secondary)
                }
                Text("Stop with the floating Stop button or the Dock icon.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 12)
            Button {
                Task { await recorder.begin(settings.makeOptions()) }
            } label: {
                HStack(spacing: 12) {
                    Circle().fill(.white).frame(width: 16, height: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Start Recording").font(.system(size: 17, weight: .semibold))
                        Text("after a 3-second countdown").font(.system(size: 11)).opacity(0.85)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 26).padding(.vertical, 14)
                .background(
                    Capsule().fill(LinearGradient(
                        colors: [Palette.record, Palette.record.opacity(0.78)], startPoint: .top, endPoint: .bottom)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .opacity(canRecord ? 1 : 0.35)
            .disabled(!canRecord)
        }
    }
}

private struct CardHint: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(.secondary)
            if !text.isEmpty {
                Text(text).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 8)
            }
        }
    }
}

/// Title row shared by every source card: icon, name and the on/off switch.
private struct CardHeader: View {
    let title: String
    let symbol: String
    var tint: Color = .white
    @Binding var isOn: Bool
    var trailing: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(isOn ? tint : Color.secondary).frame(width: 18)
            Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                .foregroundStyle(isOn ? Color.white : Color.secondary)
            Spacer(minLength: 6)
            if let trailing, isOn {
                Text(trailing).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            }
            Toggle("", isOn: $isOn).toggleStyle(.switch).controlSize(.small).labelsHidden().tint(tint == .white ? .green : tint)
        }
    }
}

private struct VideoCard<Preview: View, Footer: View>: View {
    let title: String
    let symbol: String
    @Binding var isOn: Bool
    let width: CGFloat
    @ViewBuilder var preview: () -> Preview
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(title: title, symbol: symbol, isOn: $isOn)
            ZStack {
                Palette.well
                if isOn { preview() } else { CardHint(symbol: "slash.circle", text: "Off") }
            }
            .frame(width: width - 24, height: (width - 24) * 10 / 16)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            if isOn { footer() }
        }
        .padding(12)
        .frame(width: width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.card))
    }
}

extension VideoCard where Footer == EmptyView {
    init(title: String, symbol: String, isOn: Binding<Bool>, width: CGFloat, @ViewBuilder preview: @escaping () -> Preview) {
        self.init(title: title, symbol: symbol, isOn: isOn, width: width, preview: preview, footer: { EmptyView() })
    }
}

/// An audio source shown as a scrolling waveform of the last few seconds.
private struct AudioCard: View {
    let title: String
    let symbol: String
    let tint: Color
    @Binding var isOn: Bool
    let history: [Float]
    let width: CGFloat

    private var decibels: Float {
        let peak = history.suffix(8).max() ?? 0
        return peak > 0 ? 20 * log10(peak) : -.infinity
    }

    private var readout: String {
        decibels.isFinite ? String(format: "%.0f dB", max(decibels, -99)) : "silent"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(title: title, symbol: symbol, tint: tint, isOn: $isOn, trailing: readout)
            ZStack {
                Palette.well
                if isOn {
                    Waveform(history: history, tint: tint)
                } else {
                    Text("Off").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: width - 24, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(12)
        .frame(width: width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.card))
    }
}

/// Mirrored bars, newest on the right. Bar height follows loudness in dB
/// (-60 dB to 0 dB), and bars turn red when close to clipping.
private struct Waveform: View {
    let history: [Float]
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let count = history.count
            guard count > 0 else { return }
            let step = size.width / CGFloat(count)
            let barWidth = max(1, step * 0.62)
            let mid = size.height / 2
            for (index, level) in history.enumerated() {
                let db = level > 0 ? 20 * log10(level) : -60
                let fraction = CGFloat(min(1, max(0, (db + 60) / 60)))
                let half = max(0.75, fraction * (mid - 4))
                let rect = CGRect(x: CGFloat(index) * step + (step - barWidth) / 2, y: mid - half, width: barWidth, height: half * 2)
                // Older bars fade out toward the left edge.
                let age = Double(index) / Double(max(count - 1, 1))
                let color = db > -3 ? Palette.record : tint
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color.opacity(0.25 + 0.75 * age)))
            }
        }
        .padding(.horizontal, 8)
    }
}

/// The big 3-2-1 shown in the middle of the screen before recording starts.
/// Clicking it cancels.
@MainActor
final class CountdownOverlay {
    static let shared = CountdownOverlay()
    private var window: NSWindow?
    private let model = CountdownModel()

    func show(_ number: Int, on screen: NSScreen?, onCancel: @escaping () -> Void) {
        model.number = number
        model.onCancel = onCancel
        let window = self.window ?? makeWindow()
        self.window = window
        let frame = (screen ?? NSScreen.main ?? NSScreen.screens[0]).frame
        let size = CGSize(width: 260, height: 300)
        window.setFrame(CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                               width: size.width, height: size.height), display: true)
        window.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: CountdownView(model: model))
        return window
    }
}

@MainActor
private final class CountdownModel: ObservableObject {
    @Published var number = 3
    var onCancel: () -> Void = {}
}

private struct CountdownView: View {
    @ObservedObject var model: CountdownModel

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.black.opacity(0.72))
                Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 3)
                Text("\(model.number)")
                    .font(.system(size: 130, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            }
            .frame(width: 240, height: 240)
            Text("Click to cancel")
                .font(.callout).foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.72)))
        }
        .frame(width: 260, height: 300)
        .contentShape(Rectangle())
        .onTapGesture { model.onCancel() }
    }
}

/// A small floating Stop control with the elapsed time, shown while recording.
/// CaptureDesktop's windows are excluded from capture, so it never appears in the video.
@MainActor
final class RecordingHUD {
    static let shared = RecordingHUD()
    private var panel: NSPanel?

    func show(on screen: NSScreen?, onStop: @escaping () -> Void) {
        hide()
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hosting = NSHostingView(rootView: RecordingHUDView(started: Date(), onStop: onStop))
        panel.contentView = hosting
        let size = hosting.fittingSize
        let visible = (screen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        panel.setFrame(CGRect(x: visible.maxX - size.width - 24, y: visible.minY + 24, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct RecordingHUDView: View {
    let started: Date
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Color.red).frame(width: 12, height: 12)
            Text(started, style: .timer)
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .frame(minWidth: 52, alignment: .leading)
            Button(action: onStop) {
                Label("Stop", systemImage: "stop.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Color(red: 0.86, green: 0.2, blue: 0.2)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.85)))
        .fixedSize()
    }
}
