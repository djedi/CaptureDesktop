import AppKit
import Combine
import SwiftUI

/// The menu bar icon and the panel that drops down from it.
@MainActor
final class MenuBarController: NSObject, NSWindowDelegate {
    static let shared = MenuBarController()
    private var item: NSStatusItem?
    private var panel: MenuPanel?
    private var stateWatch: AnyCancellable?
    private var outsideClicks: Any?
    private var closedAt = Date.distantPast
    /// The size the menu's content last asked for.
    private var contentSize = CGSize.zero

    func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(toggle)
        self.item = item
        stateWatch = Recorder.shared.$state.sink { [weak self] state in
            let recording = state == .recording
            let image = NSImage(systemSymbolName: recording ? "stop.circle.fill" : "record.circle",
                                accessibilityDescription: recording ? "CaptureDesktop, recording" : "CaptureDesktop")
            self?.item?.button?.image = image
        }
    }

    @objc private func toggle() {
        if panel?.isVisible == true {
            close()
        } else if Date().timeIntervalSince(closedAt) > 0.25 {
            // The click that opens the panel can also be the one that just closed it
            // (it took the keyboard focus away first): that click only closes.
            open()
        }
    }

    private func open() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Before the content has reported its size, the panel's starting size stands in.
        place(panel, size: contentSize == .zero ? panel.frame.size : contentSize)
        panel.makeKeyAndOrderFront(nil)
        // Nothing starts focused, so no focus ring shows until the keyboard is used.
        panel.makeFirstResponder(nil)
        // AppKit clears the highlight when the click ends, so set it after that.
        DispatchQueue.main.async { [weak self] in
            if self?.panel?.isVisible == true { self?.item?.button?.highlight(true) }
        }
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    func close() {
        guard panel?.isVisible == true else { return }
        closedAt = Date()
        panel?.orderOut(nil)
        item?.button?.highlight(false)
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    /// Called by the menu as its content grows or shrinks.
    fileprivate func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        contentSize = size
        guard let panel else { return }
        place(panel, size: size)
        panel.invalidateShadow()
    }

    /// Hang the panel under the menu bar icon, kept inside the screen.
    private func place(_ panel: NSPanel, size: CGSize) {
        guard let anchor = item?.button?.window else { return }
        let screen = (anchor.screen ?? NSScreen.main)?.visibleFrame ?? anchor.frame
        var x = anchor.frame.midX - size.width / 2
        x = max(screen.minX + 8, min(x, screen.maxX - size.width - 8))
        panel.setFrame(CGRect(x: x, y: anchor.frame.minY - 6 - size.height, width: size.width, height: size.height), display: true)
    }

    private func makePanel() -> MenuPanel {
        let panel = MenuPanel(contentRect: CGRect(x: 0, y: 0, width: MenuView.width, height: 300),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        let view = MenuView()
            .environmentObject(Recorder.shared)
            .environmentObject(CaptureSettings.shared)
            .environment(\.colorScheme, .dark)
        let hosting = NSHostingView(rootView: view)
        // The panel follows the content's size (see `resize`), not the other way round.
        hosting.sizingOptions = []
        panel.contentView = hosting
        return panel
    }
}

/// Borderless panels refuse the keyboard focus by default; this one needs it
/// so it can close when the focus moves elsewhere.
private final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        MenuBarController.shared.close()
    }
}

/// The menu bar panel: source switches, the record button and a few commands.
struct MenuView: View {
    static let width: CGFloat = 320

    @EnvironmentObject private var recorder: Recorder
    @EnvironmentObject private var settings: CaptureSettings
    @AppStorage(SourcePrefs.screenKey) private var screen = true
    @AppStorage(SourcePrefs.cameraKey) private var camera = true
    @AppStorage(SourcePrefs.microphoneKey) private var microphone = true
    @AppStorage(SourcePrefs.systemAudioKey) private var systemAudio = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            VStack(spacing: 0) {
                SourceRow(title: "Screen", symbol: "display", tint: .green, isOn: $screen)
                if screen {
                    ScreenOptionsView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 40).padding(.trailing, 12).padding(.bottom, 10)
                }
                rule
                SourceRow(title: "Camera", symbol: "web.camera", tint: .green, isOn: $camera)
                rule
                SourceRow(title: "Microphone", symbol: "mic.fill", tint: Palette.microphone, isOn: $microphone)
                rule
                SourceRow(title: "System Audio", symbol: "speaker.wave.2.fill", tint: Palette.systemAudio, isOn: $systemAudio)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Palette.card))
            .disabled(recorder.state != .idle)

            recordButton

            if let message = recorder.message {
                // Capped so the panel's height stays bounded; the full text is in the tooltip
                // and in the recorder window.
                Text(message).font(.caption).foregroundStyle(Palette.record)
                    .lineLimit(4).fixedSize(horizontal: false, vertical: true).help(message)
            }

            VStack(spacing: 1) {
                CommandRow(title: "Open Recorder Window", symbol: "macwindow") {
                    MenuBarController.shared.close()
                    RecorderWindowController.shared.show()
                }
                .disabled(recorder.state != .idle)
                if let folder = recorder.lastFolder, recorder.state == .idle {
                    CommandRow(title: "Show Last Recording", symbol: "folder") {
                        MenuBarController.shared.close()
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                }
                CommandRow(title: "Quit CaptureDesktop", symbol: "power") {
                    MenuBarController.shared.close()
                    NSApp.terminate(nil)
                }
                .disabled(recorder.state != .idle)
            }
        }
        .padding(12)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(Palette.window)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { MenuBarController.shared.resize(to: $0) }
        .onChange(of: [screen, camera, microphone, systemAudio]) { _, _ in PreviewEngine.shared.refresh() }
    }

    private var rule: some View {
        Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.leading, 40)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 28, height: 28)
            Text("CaptureDesktop").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(recorder.state == .recording ? Palette.record : Color.white.opacity(0.3))
                    .frame(width: 7, height: 7)
                if recorder.state == .recording, let started = recorder.recordingStarted {
                    Text(started, style: .timer).font(.system(size: 12, weight: .medium, design: .monospaced))
                } else {
                    Text(status).font(.system(size: 12))
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4).padding(.top, 2)
    }

    private var status: String {
        switch recorder.state {
        case .idle: return "Ready"
        case .countdown(let number): return "Starting in \(number)"
        case .starting: return "Starting…"
        case .recording: return "Recording"
        case .stopping: return "Finishing…"
        }
    }

    private var canPress: Bool {
        switch recorder.state {
        case .idle: return (screen || camera || microphone || systemAudio) && (!screen || settings.target != nil)
        case .countdown, .recording: return true
        case .starting, .stopping: return false
        }
    }

    private var recordButton: some View {
        let isCountdown: Bool = { if case .countdown = recorder.state { return true } else { return false } }()
        let title: String = {
            switch recorder.state {
            case .idle: return "Start Recording"
            case .countdown: return "Cancel"
            case .starting: return "Starting…"
            case .recording: return "Stop Recording"
            case .stopping: return "Finishing…"
            }
        }()
        let fill = isCountdown ? Color.white.opacity(0.16) : Palette.record
        return Button(action: toggleRecording) {
            HStack(spacing: 8) {
                if recorder.state == .recording {
                    RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 10, height: 10)
                } else if recorder.state == .idle {
                    Circle().fill(.white).frame(width: 10, height: 10)
                }
                Text(title).font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(
                LinearGradient(colors: [fill, fill.opacity(0.8)], startPoint: .top, endPoint: .bottom)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
        .opacity(canPress ? 1 : 0.35)
        .disabled(!canPress)
    }

    private func toggleRecording() {
        Task {
            switch recorder.state {
            case .recording:
                MenuBarController.shared.close()
                await recorder.stop()
            case .countdown:
                recorder.cancelCountdown()
            case .idle:
                MenuBarController.shared.close()
                await recorder.begin(settings.makeOptions())
            default: break
            }
        }
    }
}

/// One source: icon, name and its on/off switch.
private struct SourceRow: View {
    let title: String
    let symbol: String
    let tint: Color
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13))
                .foregroundStyle(isOn ? tint : Color.secondary).frame(width: 18)
            Text(title).font(.system(size: 13)).foregroundStyle(isOn ? Color.white : Color.secondary)
            Spacer()
            Toggle(title, isOn: $isOn).toggleStyle(.switch).controlSize(.small).labelsHidden().tint(tint)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }
}

/// A menu-style command that lights up under the pointer.
private struct CommandRow: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 18)
                Text(title).font(.system(size: 13)).foregroundStyle(.white)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(hovering && isEnabled ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovering = $0 }
    }
}
