import ApplicationServices
import CoreGraphics

/// One half of a held key, for buttons that act like a held keyboard key (`press` mode).
public enum KeyEvent: Equatable, Sendable {
    case down(isRepeat: Bool)
    case up
}

public enum KeyInjector {
    /// Posts a key down + key up system-wide (a single click). Requires Accessibility permission.
    public static func send(_ keyCode: CGKeyCode) {
        post(keyCode, .down(isRepeat: false))
        post(keyCode, .up)
    }

    /// Posts one key down or key up system-wide. A repeat key down is flagged as auto-repeat,
    /// the way a physical keyboard reports a key that is held. Requires Accessibility permission.
    public static func post(_ keyCode: CGKeyCode, _ event: KeyEvent) {
        let src = CGEventSource(stateID: .hidSystemState)
        let isDown: Bool
        if case .down = event { isDown = true } else { isDown = false }
        guard let cgEvent = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: isDown) else { return }
        if case .down(isRepeat: true) = event {
            cgEvent.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        }
        cgEvent.post(tap: .cghidEventTap)
    }

    /// Returns whether the process is trusted for Accessibility; shows the system prompt if not.
    @discardableResult
    public static func checkAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}
