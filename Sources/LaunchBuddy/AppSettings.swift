import SwiftUI
import Foundation

struct AppSettings {
    private let scriptPathKey = "scriptPath"
    private let restoreOnLaunchKey = "restoreOnLaunch"
    private let workingDirectoryKey = "workingDirectory"
    private let restartOnExitKey = "restartOnExit"
    private let scriptArgumentsKey = "scriptArguments"
    private let extraEnvironmentKey = "extraEnvironment"

    var scriptPath: String {
        get {
            UserDefaults.standard.string(forKey: scriptPathKey) ?? ""
        }
        set {
            UserDefaults.standard.set(newValue, forKey: scriptPathKey)
        }
    }

    var restoreOnLaunch: Bool {
        get {
            UserDefaults.standard.bool(forKey: restoreOnLaunchKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: restoreOnLaunchKey)
        }
    }

    /// Directory the script runs in. Empty means "the script's own directory".
    var workingDirectory: String {
        get {
            UserDefaults.standard.string(forKey: workingDirectoryKey) ?? ""
        }
        set {
            UserDefaults.standard.set(newValue, forKey: workingDirectoryKey)
        }
    }

    /// Watchdog: when the script exits on its own, relaunch it with the
    /// same parameters.
    var restartOnExit: Bool {
        get {
            UserDefaults.standard.bool(forKey: restartOnExitKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: restartOnExitKey)
        }
    }

    /// Arguments passed to the script, whitespace-separated. Quotes are
    /// honored so `one "two words" three` becomes three arguments.
    var scriptArguments: String {
        get {
            UserDefaults.standard.string(forKey: scriptArgumentsKey) ?? ""
        }
        set {
            UserDefaults.standard.set(newValue, forKey: scriptArgumentsKey)
        }
    }

    /// Extra environment for the script, one `KEY=VALUE` per line. Merged
    /// over the inherited environment (and over the interpreter unbuffering
    /// hints) so a line like `PYTHONUNBUFFERED=0` can override a default.
    var extraEnvironment: String {
        get {
            UserDefaults.standard.string(forKey: extraEnvironmentKey) ?? ""
        }
        set {
            UserDefaults.standard.set(newValue, forKey: extraEnvironmentKey)
        }
    }

    /// Inline problem for the script-path field: an unset path (empty) is
    /// fine, and a path that exists is fine even if not executable
    /// (start() chmods it); only a missing file is an error.
    static func scriptPathProblem(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        return FileManager.default.fileExists(atPath: path)
            ? nil
            : "File not found: \(path)"
    }
}
