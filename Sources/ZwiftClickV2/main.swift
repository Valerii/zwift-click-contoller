import Foundation
import ZwiftClickV2Core

// Line-buffer stdout so the LaunchAgent log file is written in real time.
setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
    Usage: ZwiftClickV2 [--config <path>] [--only v1|v2] [--debug]
           ZwiftClickV2 --write-config [--config <path>]

      --config <path>   Config file (default: \(Config.defaultPath))
      --only v1|v2      Use only this controller version (overrides "controllers" in the config)
      --write-config    Write the default config file and exit (never overwrites)
      --debug           Log every raw BLE packet and discovered device
    """

let args = CommandLine.arguments

func value(after flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

if args.contains("--help") || args.contains("-h") {
    print(usage)
    exit(0)
}

let configPath = value(after: "--config") ?? Config.defaultPath

if args.contains("--write-config") {
    do {
        try Config.writeDefault(to: configPath)
        print("Default config written to \(configPath)")
        exit(0)
    } catch {
        print("Could not write config: \(error.localizedDescription)")
        exit(1)
    }
}

Log.debugEnabled = args.contains("--debug")

// Checked before the single-instance takeover, so a typo never stops the running copy.
var onlyVersion: String?
if args.contains("--only") {
    guard let version = value(after: "--only"), DeviceKind.kinds(forVersion: version) != nil else {
        print("--only needs v1 or v2.\n\n\(usage)")
        exit(1)
    }
    onlyVersion = version.lowercased()
}

// Only one copy may run, since a controller can be connected to just one app. The newest copy wins:
// it stops the running one (which disconnects the controllers cleanly) and takes over.
let instanceLock: InstanceLock?
do {
    instanceLock = try InstanceLock.takeOver { pid in
        Log.info("Another ZwiftClickV2 is running (PID \(pid)) - stopping it and taking over the controllers...")
    }
} catch InstanceLock.LockError.alreadyRunning(let pid) {
    let who = pid.map { "PID \($0)" } ?? "another process"
    print("ZwiftClickV2 is already running (\(who)) and could not be stopped. Quit it first, then retry.")
    exit(1)
} catch {
    // A lock that can't be created must not stop the app from working.
    Log.info("Warning: single-instance check unavailable (\(error)). Continuing.")
    instanceLock = nil
}

var config = Config.load(from: configPath)
if let onlyVersion { config.controllers = [onlyVersion] }
let resolved = config.resolve()
resolved.errors.forEach { Log.info("Config error: \($0)") }
Log.info("Controllers: \(DeviceKind.summary(of: resolved.kinds))\(onlyVersion == nil ? "" : " (--only)")")

if !KeyInjector.checkAccessibility() {
    Log.info("Accessibility permission required for keyboard injection.")
    Log.info("Grant access in System Settings > Privacy & Security > Accessibility, then relaunch.")
}

let manager = ClickV2Manager(config: resolved, startEnabled: config.watchApp == nil)

var watcher: AppWatcher?
if let target = config.watchApp {
    let w = AppWatcher(appNameOrBundleID: target)
    w.onLaunch = { manager.enable() }
    w.onQuit = { manager.disable() }
    w.start()
    watcher = w
}

// Ctrl+C / `launchctl unload` (SIGTERM): disconnect the controllers cleanly so they are free right away.
// A second signal while shutting down exits immediately.
var shuttingDown = false
let signalSources: [DispatchSourceSignal] = [SIGINT, SIGTERM].map { sig in
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        if shuttingDown { exit(0) }
        shuttingDown = true
        Log.info("Shutting down - disconnecting controllers...")
        watcher?.stop()
        manager.shutdown {
            Log.info("Disconnected. Bye.")
            exit(0)
        }
    }
    source.resume()
    return source
}

withExtendedLifetime((manager, watcher, instanceLock, signalSources)) {
    RunLoop.main.run()
}
