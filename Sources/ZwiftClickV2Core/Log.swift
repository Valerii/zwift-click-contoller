import Foundation

public enum Log {
    public static var debugEnabled = false

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    public static func info(_ message: String) {
        print("\(formatter.string(from: Date())) \(message)")
    }

    public static func debug(_ message: @autoclosure () -> String) {
        guard debugEnabled else { return }
        info("[debug] \(message())")
    }
}
