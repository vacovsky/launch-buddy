import SwiftUI
import AppKit

class AppLifecycle: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        ScriptSignalGuard.install()
        let settings = AppSettings()
        if settings.restoreOnLaunch {
            ProcessManager.shared.start(scriptPath: settings.scriptPath,
                                        workingDirectory: settings.workingDirectory)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ProcessManager.shared.killSync()
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) {
        // Second safety net for the graceful-quit path; the signal guard
        // covers SIGTERM/SIGINT, where AppKit skips the delegate entirely.
        ProcessManager.shared.killSync()
    }
}

@main
struct LaunchBuddyApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) var lifecycle
    private let pm = ProcessManager.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarControl()
        } label: {
            Label("Launch Buddy", systemImage: pm.running ? "brain.fill" : "brain")
        }
        .menuBarExtraStyle(.menu)

        Window("Output", id: "output") {
            OutputView()
        }
        .defaultSize(width: 600, height: 400)

        Window("Settings", id: "settings") {
            SettingsView()
        }
        .windowResizability(.contentSize)
    }
}
