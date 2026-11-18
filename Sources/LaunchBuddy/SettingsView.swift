import SwiftUI
import ServiceManagement
import AppKit

struct SettingsView: View {
    @State private var settings = AppSettings()
    @State private var isShowingFilePicker = false
    @State private var launchAtLogin = false
    @State private var loginItemError: String?
    @State private var scriptPathError: String?

    var body: some View {
        Form {
            Section("Script") {
                HStack {
                    TextField("Script path", text: $settings.scriptPath)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: settings.scriptPath) { _, _ in
                        validateScriptPath()
                    }

                    Button("Browse…") {
                        isShowingFilePicker = true
                    }
                }

                if let scriptPathError {
                    Text(scriptPathError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack {
                    TextField("Working directory (empty = script's directory)",
                              text: $settings.workingDirectory)
                        .textFieldStyle(.roundedBorder)

                    Button("Browse…") {
                        browseForDirectory()
                    }
                }

                TextField("Arguments (whitespace-separated, quotes allowed)",
                          text: $settings.scriptArguments)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)

                TextField("Environment (one KEY=VALUE per line)",
                          text: $settings.extraEnvironment)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .lineLimit(3...8)
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

                Toggle("Restart script on exit", isOn: $settings.restartOnExit)
            }
        }
        .formStyle(.grouped)
        .padding(4)
        .onAppear {
            launchAtLogin = isRegisteredForLogin()
            validateScriptPath()
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

    /// Recomputes the inline error for the configured script path. Called as
    /// the field changes (typing or Browse) and when the window opens, so a
    /// path deleted since the last session is flagged immediately.
    private func validateScriptPath() {
        scriptPathError = AppSettings.scriptPathProblem(settings.scriptPath)
    }
}
