import SwiftUI

struct OutputView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @State private var pinned = true
    @State private var task: Task<Void, Never>?
    @State private var scrollId = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Script Output")
                    .font(.headline)

                Spacer()

                Button {
                    pinned.toggle()
                    if pinned {
                        scrollToBottom()
                    }
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

            ScrollViewReader { proxy in
                ScrollView {
                    TextEditor(text: $text)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        .scrollDisabled(true)
                        .id(scrollId)
                }
                .background(Color(.textBackgroundColor))
                .onChange(of: scrollId) {
                    if pinned {
                        withAnimation(nil) {
                            proxy.scrollTo(scrollId, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .task {
            text = ProcessManager.shared.outputLines.joined(separator: "\n")
            scrollToBottom()
            task = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    Task { @MainActor in
                        refreshText()
                    }
                }
            }
        }
    }

    private func scrollToBottom() {
        scrollId += 1
    }

    private func refreshText() {
        let newLines = ProcessManager.shared.outputLines
        let newText = newLines.joined(separator: "\n")
        if newText != text {
            text = newText
            if pinned {
                scrollToBottom()
            }
        }
    }
}
