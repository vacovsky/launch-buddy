import SwiftUI
import AppKit

struct OutputView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pinned = true
    /// Full text shown in the text view; kept in sync incrementally so a
    /// chunk appends only its suffix (no whole-buffer re-layout).
    @State private var text: String = ProcessManager.shared.outputLines.joined(separator: "\n")
    /// Number of lines currently in `text`, tracked so the scrollback trim
    /// below does not have to rescan the string on every chunk.
    @State private var renderedLineCount = ProcessManager.shared.outputLines.count
    /// Run whose output `text` currently reflects; a new run re-syncs.
    @State private var syncedRunID: UInt64 = ProcessManager.shared.runID

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

                Button {
                    clearOutput()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear output")

                Button {
                    saveOutput()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Save output to a file")

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
        .onAppear {
            resyncIfStale()
        }
        // A new run: replace the view's content with the (empty) fresh
        // buffer, then pick up anything already emitted.
        .onChange(of: ProcessManager.shared.runID) { _, _ in
            guard ProcessManager.shared.runID != syncedRunID else { return }
            syncedRunID = ProcessManager.shared.runID
            text = ProcessManager.shared.outputLines.joined(separator: "\n")
            renderedLineCount = ProcessManager.shared.outputLines.count
            append(ProcessManager.shared.drainOutput())
        }
        // Same run, new output: append only the delta. If the buffer was
        // cleared (or a run restarted) while showing content, reset first.
        .onChange(of: ProcessManager.shared.outputLines) { _, lines in
            if lines.isEmpty && !text.isEmpty {
                text = ""
                renderedLineCount = 0
            }
            append(ProcessManager.shared.drainOutput())
        }
    }

    /// Appends newly emitted text to the view, trimming scrollback so the
    /// window mirrors the `maxOutputLines` cap of the manager's buffer.
    private func append(_ suffix: String) {
        guard !suffix.isEmpty else { return }
        text += suffix
        renderedLineCount += suffix.unicodeScalars.lazy.filter { $0 == "\n" }.count
        trimScrollback()
    }

    /// Opening the window (or reopening it) mid-run: adopt the manager's
    /// current buffer plus whatever has been emitted since.
    private func resyncIfStale() {
        let pm = ProcessManager.shared
        if pm.runID != syncedRunID {
            syncedRunID = pm.runID
            text = pm.outputLines.joined(separator: "\n")
            renderedLineCount = pm.outputLines.count
        }
        append(pm.drainOutput())
    }

    /// Drop the oldest lines beyond the cap. The wrapper detects the
    /// front-removal and trims the text storage incrementally.
    private func trimScrollback() {
        let max = ProcessManager.maxOutputLines
        guard renderedLineCount > max else { return }
        let drop = renderedLineCount - max
        var seen = 0
        var cut = text.startIndex
        for i in text.indices where text[i] == "\n" {
            seen += 1
            if seen == drop {
                cut = text.index(after: i)
                break
            }
        }
        text.removeSubrange(text.startIndex..<cut)
        renderedLineCount = max
    }

    /// Clears the view and the manager's buffer for the current run; the
    /// running script continues and its new output is captured fresh.
    private func clearOutput() {
        ProcessManager.shared.clearOutput()
        text = ""
        renderedLineCount = 0
    }

    /// Writes the current view content to a user-chosen file.
    private func saveOutput() {
        guard !text.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "script-output.txt"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
