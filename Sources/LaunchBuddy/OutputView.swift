import SwiftUI

struct OutputView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pinned = true
    @State private var text: String = ProcessManager.shared.outputLines.joined(separator: "\n")

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Script Output")
                    .font(.headline)

                if let exit = ProcessManager.shared.lastExit {
                    Text(exit.summary)
                        .font(.caption)
                        .foregroundStyle(exit.isClean ? Color.secondary : Color.red)
                }

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

            NSTextViewWrapper(
                text: $text,
                pinned: pinned
            )
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .onChange(of: ProcessManager.shared.outputLines) { _, lines in
            text = lines.joined(separator: "\n")
        }
    }
}
