import SwiftUI
import ServiceManagement
import AppKit

struct SettingsView: View {
    @State private var settings = AppSettings()
    @State private var isShowingFilePicker = false
    @State private var launchAtLogin = false
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section("Script") {
                HStack {
                    TextField("Script path", text: $settings.scriptPath)
                        .textFieldStyle(.roundedBorder)

                    Button("Browse…") {
                        isShowingFilePicker = true
                    }
                }

                HStack {
                    TextField("Working directory (empty = script's directory)",
                              text: $settings.workingDirectory)
                        .textFieldStyle(.roundedBorder)

                    Button("Browse…") {
                        browseForDirectory()
                    }
                }
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }

                if let loginItemError {
                    Text(loginItemError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Toggle("Restore script on launch", isOn: $settings.restoreOnLaunch)
            }
        }
        .formStyle(.grouped)
        .padding(4)
        .onAppear {
            launchAtLogin = isRegisteredForLogin()
        }
        .fileImporter(
            isPresented: $isShowingFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                settings.scriptPath = url.path
            }
        }
    }

    private func isRegisteredForLogin() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        let appService = SMAppService.mainApp
        do {
            if enabled {
                try appService.register()
            } else {
                try appService.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
            launchAtLogin = isRegisteredForLogin()
        }
    }

    /// NSOpenPanel-based directory picker; SwiftUI's fileImporter cannot
    /// select folders on macOS.
    private func browseForDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            settings.workingDirectory = url.path
        }
    }
}
