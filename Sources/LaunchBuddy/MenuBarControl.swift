import SwiftUI
import AppKit

struct MenuBarControl: View {
    private let pm = ProcessManager.shared
    private let settings = AppSettings()
    @Environment(\.openWindow) private var openWindow
    @State private var toggledOn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                toggledOn.toggle()
                if toggledOn {
                    pm.start(scriptPath: settings.scriptPath)
                } else {
                    pm.stop()
                }
            } label: {
                HStack {
                    Toggle(isOn: .constant(pm.running)) {}
                        .toggleStyle(.switch)
                        .scaleEffect(0.8)
                        .allowsHitTesting(false)
                    Text(pm.running ? "Stop Script" : "Start")
                        .foregroundStyle(pm.running ? .green : .primary)
                }
            }
            .buttonStyle(.plain)

            if !settings.scriptPath.isEmpty {
                Text(settings.scriptPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let launchError = pm.launchError {
                Text(launchError)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            Divider()

            Button("View Output") {
                openWindow(id: "output")
            }

            Button("Settings…") {
                openWindow(id: "settings")
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .onChange(of: pm.running) {
            if toggledOn != pm.running {
                toggledOn = pm.running
            }
        }
    }
}
