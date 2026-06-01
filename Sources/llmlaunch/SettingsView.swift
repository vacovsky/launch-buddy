import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @State private var settings = AppSettings()
    @State private var isShowingFilePicker = false
    @State private var launchAtLogin: Bool = false

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
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
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
            allowedContentTypes: [.executable],
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
        } catch {
            print("Failed to update login items: \(error)")
        }
    }
}
