import AppKit
import Carbon.HIToolbox

/// The system-wide Start/Stop shortcut, Option-Shift-Command-R.
///
/// Uses Carbon's `RegisterEventHotKey`, which works while other apps are in
/// front and needs no Accessibility permission. The R is the key that types R
/// in the current keyboard layout, re-resolved when the layout changes.
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()
    /// Shown in the UI next to the controls it duplicates.
    static let label = "⌥⇧⌘R"

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var layoutObserver: NSObjectProtocol?

    func install() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in Recorder.shared.toggleFromShortcut() }
            return noErr
        }, 1, &spec, nil, &handler)
        guard status == noErr else {
            NSLog("CaptureDesktop: could not install the hotkey handler (\(status))")
            return
        }
        register()
        layoutObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in GlobalHotKey.shared.register() }
        }
    }

    private func register() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        let id = EventHotKeyID(signature: OSType(0x4344_534B), id: 1) // "CDSK"
        let keyCode = Self.keyCode(for: "r") ?? UInt32(kVK_ANSI_R)
        let result = RegisterEventHotKey(keyCode, UInt32(optionKey | shiftKey | cmdKey), id,
                                         GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr {
            // Another app already owns the combination; the buttons still work.
            NSLog("CaptureDesktop: could not register \(Self.label) (\(result))")
            hotKey = nil
        }
    }

    /// The virtual key code that types `character` (unmodified) in the current layout.
    private static func keyCode(for character: String) -> UInt32? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> UInt32? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in UInt16(0)..<128 {
                var deadKeys: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count,
                                            &length, &chars)
                if status == noErr, length == 1, String(utf16CodeUnits: chars, count: 1).lowercased() == character {
                    return UInt32(code)
                }
            }
            return nil
        }
    }
}
