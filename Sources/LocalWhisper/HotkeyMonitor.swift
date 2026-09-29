import AppKit
import Carbon.HIToolbox

/// Watches the right Option key globally.
///
/// - Hold right ⌥, talk, release → `onStop`.
/// - Quick tap (< 0.3 s) → recording stays on (hands-free); tap again → `onStop`.
/// - Esc while recording, or pressing another key while holding ⌥ (a shortcut chord) → `onCancel`.
/// - ⇧ held when right ⌥ goes down starts *prompt mode* (`onStart(true)`); pressing ⇧ at any
///   point while recording switches to it (`onPromptMode`), so the key order doesn't matter.
@MainActor
final class HotkeyMonitor {
    var onStart: (_ promptMode: Bool) -> Void = { _ in }
    var onPromptMode: () -> Void = {}
    /// Esc pressed while no recording is running (e.g. during a prompt rewrite).
    var onEscapeWhileIdle: () -> Void = {}
    var onStop: () -> Void = {}
    var onCancel: () -> Void = {}

    private enum Mode { case idle, holding, latched }
    private var mode: Mode = .idle
    private var pressedAt = Date()
    private var rightOptionDown = false
    private var monitors: [Any] = []

    private static let rightOptionKeyCode: UInt16 = UInt16(kVK_RightOption)
    private static let tapThreshold: TimeInterval = 0.3

    func start() {
        stop()
        let flags: (NSEvent) -> Void = { [weak self] event in self?.handleFlags(event) }
        let keys: (NSEvent) -> Void = { [weak self] event in self?.handleKeyDown(event) }

        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keys) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { flags($0); return $0 }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { keys($0); return $0 }) { monitors.append(m) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    /// Called by the app if recording ends for another reason (error, cancel from menu).
    func reset() { mode = .idle }

    /// Recording was started from the menu: the next right ⌥ press finishes it.
    func latch() { mode = .latched }

    private func handleFlags(_ event: NSEvent) {
        if mode != .idle, event.modifierFlags.contains(.shift) { onPromptMode() }
        guard event.keyCode == Self.rightOptionKeyCode else { return }
        let isDown = event.modifierFlags.contains(.option)
        guard isDown != rightOptionDown else { return }
        rightOptionDown = isDown

        switch (mode, isDown) {
        case (.idle, true):
            mode = .holding
            pressedAt = Date()
            onStart(event.modifierFlags.contains(.shift))
        case (.holding, false):
            if Date().timeIntervalSince(pressedAt) < Self.tapThreshold {
                mode = .latched
            } else {
                mode = .idle
                onStop()
            }
        case (.latched, true):
            mode = .idle
            onStop()
        default:
            break
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        guard !Typer.isOurs(event) else { return }
        guard mode != .idle else {
            if event.keyCode == UInt16(kVK_Escape) { onEscapeWhileIdle() }
            return
        }
        if event.keyCode == UInt16(kVK_Escape) || rightOptionDown {
            // Esc cancels; any key while ⌥ is held means the user was typing a ⌥-shortcut, not dictating.
            mode = .idle
            onCancel()
        }
    }
}
