import CoreGraphics
import Foundation

/// Keys sent for one button. `hold` defaults to `tap` (auto-repeat while held).
public struct ButtonAction: Codable, Equatable, Sendable {
    public var tap: String?
    public var hold: String?

    public init(tap: String?, hold: String? = nil) {
        self.tap = tap
        self.hold = hold
    }
}

public struct Config: Codable, Equatable {
    /// Keyed by button name (`Button.rawValue`). A button that is absent does nothing.
    public var buttons: [String: ButtonAction]
    public var holdThreshold: Double
    public var holdRepeatInterval: Double
    /// App name or bundle ID. BLE connects when it launches and disconnects when it quits.
    /// nil = stay connected all the time.
    public var watchApp: String?
    /// Which controller versions to use: "v1", "v2". Others are ignored and never connected.
    public var controllers: [String]

    public static let defaultControllers = ["v1", "v2"]

    public static let defaultButtons: [String: ButtonAction] = [
        "up":    ButtonAction(tap: "up"),
        "down":  ButtonAction(tap: "down"),
        "left":  ButtonAction(tap: "left"),
        "right": ButtonAction(tap: "right"),
        "minus": ButtonAction(tap: "i", hold: "i"),
        "plus":  ButtonAction(tap: "k", hold: "k"),
        "a":     ButtonAction(tap: "return"),
        "b":     ButtonAction(tap: "escape"),
        "y":     ButtonAction(tap: "space"),
        "z":     ButtonAction(tap: "tab"),
    ]

    public static let defaultPath = (NSHomeDirectory() as NSString)
        .appendingPathComponent(".config/zwift-click-v2/config.json")

    public init(buttons: [String: ButtonAction] = Config.defaultButtons,
                holdThreshold: Double = 0.3,
                holdRepeatInterval: Double = 0.2,
                watchApp: String? = nil,
                controllers: [String] = Config.defaultControllers) {
        self.buttons = buttons
        self.holdThreshold = holdThreshold
        self.holdRepeatInterval = holdRepeatInterval
        self.watchApp = watchApp
        self.controllers = controllers
    }

    enum CodingKeys: String, CodingKey {
        case buttons, holdThreshold, holdRepeatInterval, watchApp, controllers
    }

    // Every field is optional in the file; missing ones fall back to defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        buttons            = try c.decodeIfPresent([String: ButtonAction].self, forKey: .buttons) ?? Config.defaultButtons
        holdThreshold      = try c.decodeIfPresent(Double.self, forKey: .holdThreshold) ?? 0.3
        holdRepeatInterval = try c.decodeIfPresent(Double.self, forKey: .holdRepeatInterval) ?? 0.2
        watchApp           = try c.decodeIfPresent(String.self, forKey: .watchApp)
        controllers        = try c.decodeIfPresent([String].self, forKey: .controllers) ?? Config.defaultControllers
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(buttons, forKey: .buttons)
        try c.encode(holdThreshold, forKey: .holdThreshold)
        try c.encode(holdRepeatInterval, forKey: .holdRepeatInterval)
        try c.encode(watchApp, forKey: .watchApp) // written as null so the option is discoverable
        try c.encode(controllers, forKey: .controllers)
    }

    // MARK: Load / write

    public static func load(from path: String) -> Config {
        guard FileManager.default.fileExists(atPath: path) else {
            Log.info("No config at \(path) - using defaults. Run --write-config to create one.")
            return Config()
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let config = try JSONDecoder().decode(Config.self, from: data)
            Log.info("Loaded config from \(path)")
            return config
        } catch {
            Log.info("Config parse error in \(path): \(error). Using defaults.")
            return Config()
        }
    }

    public struct AlreadyExists: LocalizedError {
        public let path: String
        public var errorDescription: String? { "\(path) already exists - delete it first to regenerate." }
    }

    /// Writes the default config. Refuses to overwrite an existing file.
    public static func writeDefault(to path: String) throws {
        guard !FileManager.default.fileExists(atPath: path) else { throw AlreadyExists(path: path) }
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Config()).write(to: URL(fileURLWithPath: path))
    }

    // MARK: Resolve key names

    public func resolve() -> ResolvedConfig {
        var errors: [String] = []
        var actions: [Button: ResolvedButton] = [:]
        let validButtons = Button.allCases.map(\.rawValue).joined(separator: ", ")

        for name in buttons.keys.sorted() where Button(rawValue: name.lowercased()) == nil {
            errors.append("buttons.\(name): unknown button (valid: \(validButtons))")
        }

        for button in Button.allCases {
            guard let action = buttons.first(where: { $0.key.lowercased() == button.rawValue })?.value else { continue }

            func key(_ name: String?, _ field: String) -> KeyAction? {
                guard let name else { return nil }
                guard let code = Keys.code(for: name) else {
                    errors.append("buttons.\(button.rawValue).\(field): unknown key \"\(name)\"")
                    return nil
                }
                return KeyAction(name: name.lowercased(), code: code)
            }

            let tap = key(action.tap, "tap")
            let hold = action.hold == nil ? tap : key(action.hold, "hold")
            actions[button] = ResolvedButton(tap: tap, hold: hold)
        }

        var threshold = holdThreshold
        if threshold <= 0 {
            errors.append("holdThreshold must be > 0 (got \(holdThreshold)) - using 0.3")
            threshold = 0.3
        }
        var repeatInterval = holdRepeatInterval
        if repeatInterval < 0.05 {
            errors.append("holdRepeatInterval must be >= 0.05 (got \(holdRepeatInterval)) - using 0.2")
            repeatInterval = 0.2
        }

        var kinds: Set<DeviceKind> = []
        for name in controllers {
            if let matched = DeviceKind.kinds(forVersion: name) {
                kinds.formUnion(matched)
            } else {
                errors.append("controllers: unknown controller \"\(name)\" (valid: v1, v2)")
            }
        }
        if kinds.isEmpty {
            // Never end up with an app that connects to nothing because of a typo.
            errors.append("controllers: no valid controller listed - using v1 and v2")
            kinds = Set(DeviceKind.allCases)
        }

        return ResolvedConfig(actions: actions, holdThreshold: threshold,
                              holdRepeatInterval: repeatInterval, kinds: kinds, errors: errors)
    }
}

public struct KeyAction: Equatable, Sendable {
    public let name: String
    public let code: CGKeyCode
}

public struct ResolvedButton: Equatable, Sendable {
    public let tap: KeyAction?
    public let hold: KeyAction?
}

public struct ResolvedConfig: Equatable, Sendable {
    public let actions: [Button: ResolvedButton]
    public let holdThreshold: TimeInterval
    public let holdRepeatInterval: TimeInterval
    /// Controllers to scan for and connect to.
    public let kinds: Set<DeviceKind>
    public let errors: [String]
}
