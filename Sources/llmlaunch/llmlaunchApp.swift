import SwiftUI
import AppKit

class AppLifecycle: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ProcessManager.shared.killSync()
        return .terminateNow
    }
}

@main
struct llmlaunchApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) var lifecycle
    @State private var iconFilled = false
    private let pm = ProcessManager.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarControl()
        } label: {
            Label("llmlaunch", systemImage: iconFilled ? "brain.fill" : "brain")
        }
        .menuBarExtraStyle(.menu)
        .onChange(of: pm.running) {
            iconFilled = pm.running
        }

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
