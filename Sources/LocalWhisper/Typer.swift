import AppKit
import Carbon.HIToolbox

/// Types text into the focused app with synthetic Unicode key events — no clipboard involved,
/// so it can run many times per second while the user is talking.
enum Typer {
    /// Stamped on our synthetic events so the hotkey monitor can ignore them.
    static let marker: Int64 = 0x57_48_53_50 // "WHSP"

    static var canType: Bool { Paster.hasAccessibility && !IsSecureEventInputEnabled() }

    static func type(_ text: String) {
        guard !text.isEmpty else { return }
        let source = CGEventSource(stateID: .privateState)
        let units = Array(text.utf16)
        // macOS accepts at most ~20 UTF-16 units per event.
        var i = 0
        while i < units.count {
            var end = min(i + 16, units.count)
            // Don't split a surrogate pair (emoji etc).
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
            var chunk = Array(units[i..<end])
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { continue }
                event.flags = [] // don't inherit the ⌥ the user is holding
                event.setIntegerValueField(.eventSourceUserData, value: marker)
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                event.post(tap: .cgSessionEventTap)
            }
            i = end
        }
    }

    static func isOurs(_ event: NSEvent) -> Bool {
        event.cgEvent?.getIntegerValueField(.eventSourceUserData) == marker
    }
}
