import Darwin
import Foundation

/// Ensures only one ZwiftClickV2 runs per user, since a puck can only be connected to one app.
///
/// Uses flock(2) on a lock file. The kernel releases the lock when the process exits for any
/// reason (Ctrl+C, crash, kill -9), so a leftover lock file never blocks the next start.
public final class InstanceLock {
    public static let defaultPath = (NSHomeDirectory() as NSString)
        .appendingPathComponent("Library/Caches/zwift-click-v2.lock")

    public enum LockError: Error, Equatable {
        /// Another process holds the lock. `pid` is the holder's PID, if it could be read.
        case alreadyRunning(pid: pid_t?)
        /// The lock file could not be created or locked (not a sign of another instance).
        case unavailable(String)
    }

    private let fd: Int32

    /// Acquires the lock, or throws if another instance already holds it.
    public init(path: String = InstanceLock.defaultPath) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw LockError.unavailable("\(path): \(String(cString: strerror(errno)))") }

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let err = errno
            let holder = InstanceLock.readPID(fd)
            close(fd)
            if err == EWOULDBLOCK { throw LockError.alreadyRunning(pid: holder) }
            throw LockError.unavailable("\(path): \(String(cString: strerror(err)))")
        }

        // Record our PID so a second instance can say who is holding the pucks.
        ftruncate(fd, 0)
        let pidLine = "\(getpid())\n"
        _ = pidLine.withCString { write(fd, $0, strlen($0)) }
        self.fd = fd
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }

    /// Acquires the lock. If another ZwiftClickV2 holds it, asks that copy to quit (SIGTERM, which
    /// makes it disconnect the pucks cleanly), waits for it, and falls back to SIGKILL if it hangs.
    /// Never signals a process that is not ZwiftClickV2, and never signals itself.
    public static func takeOver(path: String = InstanceLock.defaultPath,
                                timeout: TimeInterval = 5,
                                onStopping: (pid_t) -> Void = { _ in }) throws -> InstanceLock {
        do {
            return try InstanceLock(path: path)
        } catch LockError.alreadyRunning(let pid) {
            guard let pid, pid != getpid(), isZwiftClickV2(pid) else {
                throw LockError.alreadyRunning(pid: pid)
            }
            onStopping(pid)
            kill(pid, SIGTERM)
            if let lock = try waitForLock(path: path, timeout: timeout) { return lock }
            kill(pid, SIGKILL)
            if let lock = try waitForLock(path: path, timeout: 1) { return lock }
            throw LockError.alreadyRunning(pid: pid)
        }
    }

    private static func waitForLock(path: String, timeout: TimeInterval) throws -> InstanceLock? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            do {
                return try InstanceLock(path: path)
            } catch LockError.alreadyRunning {
                usleep(100_000)
            }
        }
        return nil
    }

    /// True if `pid` is a running process whose executable is named ZwiftClickV2. Guards against
    /// a stale PID in the lock file having been reused by an unrelated process.
    static func isZwiftClickV2(_ pid: pid_t) -> Bool {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        return (String(cString: buffer) as NSString).lastPathComponent == "ZwiftClickV2"
    }

    private static func readPID(_ fd: Int32) -> pid_t? {
        var buffer = [UInt8](repeating: 0, count: 32)
        lseek(fd, 0, SEEK_SET)
        let count = read(fd, &buffer, buffer.count)
        guard count > 0 else { return nil }
        let text = String(decoding: buffer[0..<count], as: UTF8.self)
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
