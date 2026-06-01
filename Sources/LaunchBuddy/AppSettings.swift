import SwiftUI
import Foundation

struct AppSettings {
    private let scriptPathKey = "scriptPath"
    private let restoreOnLaunchKey = "restoreOnLaunch"

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
}
