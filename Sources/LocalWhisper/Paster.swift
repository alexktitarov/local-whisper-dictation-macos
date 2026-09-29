import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Puts text into whatever app has focus: clipboard + synthetic ⌘V, then restores the old clipboard.
enum Paster {
    enum Outcome {
        case pasted
        case copiedOnly(reason: String)
    }

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    static func promptForAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @MainActor
    static func insert(_ text: String) -> Outcome {
        let pb = NSPasteboard.general

        guard hasAccessibility else {
            setClipboard(text, on: pb)
            return .copiedOnly(reason: "Accessibility permission missing — text is on your clipboard.")
        }
        guard !IsSecureEventInputEnabled() else {
            setClipboard(text, on: pb)
            return .copiedOnly(reason: "Secure input is active (password field?) — text is on your clipboard.")
        }

        let saved = snapshot(pb)
        setClipboard(text, on: pb)
        let changeCount = pb.changeCount

        sendCommandV()

        // Give the target app time to read the pasteboard before we put the old contents back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard pb.changeCount == changeCount else { return } // user copied something else meanwhile
            restore(saved, on: pb)
        }
        return .pasted
    }

    private static func setClipboard(_ text: String, on pb: NSPasteboard) {
        pb.clearContents()
        pb.setString(text, forType: .string)
        // Ask clipboard managers to ignore this transient entry.
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
    }

    private static func sendCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]

    private static func snapshot(_ pb: NSPasteboard) -> Snapshot {
        (pb.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { dict[type] = data }
            }
            return dict
        }
    }

    private static func restore(_ saved: Snapshot, on pb: NSPasteboard) {
        pb.clearContents()
        guard !saved.isEmpty else { return }
        let items = saved.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: type) }
            return item
        }
        pb.writeObjects(items)
    }
}
