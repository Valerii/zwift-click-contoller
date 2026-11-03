import ApplicationServices
import CoreGraphics

public enum KeyInjector {
    /// Posts a key down + key up system-wide. Requires Accessibility permission.
    public static func send(_ keyCode: CGKeyCode) {
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)?.post(tap: .cghidEventTap)
    }

    /// Returns whether the process is trusted for Accessibility; shows the system prompt if not.
    @discardableResult
    public static func checkAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}
