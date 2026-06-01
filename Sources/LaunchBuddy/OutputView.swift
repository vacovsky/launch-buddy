import SwiftUI

struct OutputView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @State private var pinned = true
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Script Output")
                    .font(.headline)

                Spacer()

                Button {
                    pinned.toggle()
                } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .foregroundStyle(pinned ? .blue : .secondary)
                }
                .buttonStyle(.plain)
                .help(pinned ? "Unpin to scroll freely" : "Pin to follow output")

                Button("Close") {
                    dismiss()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            NSTextViewWrapper(text: $text, pinned: pinned, scrollId: .constant(0))
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .task {
            text = ProcessManager.shared.outputLines.joined(separator: "\n")
            task = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    Task { @MainActor in
                        let newLines = ProcessManager.shared.outputLines
                        let newText = newLines.joined(separator: "\n")
                        if newText != text {
                            text = newText
                        }
                    }
                }
            }
        }
    }
}
