import Foundation

/// Turns a button's pressed/released reports into key presses.
public protocol ButtonHandler: AnyObject {
    func update(pressed: Bool)
    /// Stops whatever the button is doing (controller disconnected, app disabled or quitting).
    func release()
}

/// Tap vs. hold detection for one button. Must be driven from the main run loop.
/// - Released before `threshold`: `onTap` once.
/// - Held past `threshold`: `onHold` once, then every `repeatInterval` until released.
public final class ButtonTracker: ButtonHandler {
    public var onTap:  (() -> Void)?
    public var onHold: (() -> Void)?

    public private(set) var isPressed = false
    private var holdFired = false
    private let threshold: TimeInterval
    private let repeatInterval: TimeInterval
    private var holdTimer: Timer?
    private var repeatTimer: Timer?

    public init(threshold: TimeInterval, repeatInterval: TimeInterval) {
        self.threshold = threshold
        self.repeatInterval = repeatInterval
    }

    public func update(pressed: Bool) {
        guard pressed != isPressed else { return }
        isPressed = pressed

        if pressed {
            holdFired = false
            holdTimer = Timer.scheduledTimer(withTimeInterval: threshold, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.holdFired = true
                self.onHold?()
                self.repeatTimer = Timer.scheduledTimer(withTimeInterval: self.repeatInterval,
                                                        repeats: true) { [weak self] _ in
                    self?.onHold?()
                }
            }
        } else {
            cancelTimers()
            // Decided by whether the hold fired, not by elapsed time, so a late timer can't swallow the press.
            if !holdFired { onTap?() }
        }
    }

    /// Abandons an in-flight press without firing anything (e.g. the puck disconnected mid-press).
    public func release() {
        isPressed = false
        holdFired = false
        cancelTimers()
    }

    private func cancelTimers() {
        holdTimer?.invalidate();   holdTimer = nil
        repeatTimer?.invalidate(); repeatTimer = nil
    }
}
