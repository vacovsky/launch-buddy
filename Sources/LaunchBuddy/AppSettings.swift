import SwiftUI
import Foundation

struct AppSettings {
    private let scriptPathKey = "scriptPath"
    private let restoreOnLaunchKey = "restoreOnLaunch"
    private let workingDirectoryKey = "workingDirectory"

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
}
