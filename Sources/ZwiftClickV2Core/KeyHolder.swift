import AppKit
import Foundation

/// Makes a button act exactly like a held keyboard key (`press` mode). Must be driven from the
/// main run loop.
/// - Button down: key down at once.
/// - While held: auto-repeat key downs after the system key-repeat delay, at the system repeat rate
///   (synthetic key events don't auto-repeat on their own).
/// - Button up, or `release()` (disconnect, shutdown): key up, so a key can never stay stuck down.
public final class KeyHolder: ButtonHandler {
    public var onDown: (() -> Void)?
    /// Called on key up with how long the key was held.
    public var onUp: ((TimeInterval) -> Void)?

    public private(set) var isPressed = false
    private var pressedAt = Date()
    private let repeatDelay: TimeInterval
    private let repeatInterval: TimeInterval
    private let send: (KeyEvent) -> Void
    private var delayTimer: Timer?
    private var repeatTimer: Timer?

    /// Your Keyboard settings ("Delay until repeat" / "Key repeat rate"), with macOS-like fallbacks.
    public static var systemRepeatDelay: TimeInterval { NSEvent.keyRepeatDelay > 0 ? NSEvent.keyRepeatDelay : 0.5 }
    public static var systemRepeatInterval: TimeInterval { NSEvent.keyRepeatInterval > 0 ? NSEvent.keyRepeatInterval : 0.083 }

    public init(repeatDelay: TimeInterval = KeyHolder.systemRepeatDelay,
                repeatInterval: TimeInterval = KeyHolder.systemRepeatInterval,
                send: @escaping (KeyEvent) -> Void) {
        self.repeatDelay = repeatDelay
        self.repeatInterval = repeatInterval
        self.send = send
    }

    public func update(pressed: Bool) {
        guard pressed != isPressed else { return }
        isPressed = pressed

        if pressed {
            pressedAt = Date()
            send(.down(isRepeat: false))
            onDown?()
            delayTimer = Timer.scheduledTimer(withTimeInterval: repeatDelay, repeats: false) { [weak self] _ in
                guard let self, self.isPressed else { return }
                self.send(.down(isRepeat: true))
                self.repeatTimer = Timer.scheduledTimer(withTimeInterval: self.repeatInterval, repeats: true) { [weak self] _ in
                    guard let self, self.isPressed else { return }
                    self.send(.down(isRepeat: true))
                }
            }
        } else {
            cancelTimers()
            send(.up)
            onUp?(Date().timeIntervalSince(pressedAt))
        }
    }

    /// Lifts the key if it is down. Unlike a tap/hold button, a held key must never be abandoned.
    public func release() {
        update(pressed: false)
    }

    private func cancelTimers() {
        delayTimer?.invalidate();  delayTimer = nil
        repeatTimer?.invalidate(); repeatTimer = nil
    }
}
