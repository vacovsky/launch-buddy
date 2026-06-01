import SwiftUI

struct NSTextViewWrapper: NSViewRepresentable {
    @Binding var text: String
    var pinned: Bool
    @Binding var scrollId: Int

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.drawsBackground = true
        textView.isRichText = false
        textView.autoresizingMask = [.width, .height]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        return textView
    }

    func updateNSView(_ nsView: NSTextView, context: Context) {
        if nsView.string != text {
            nsView.string = text
            if pinned {
                nsView.scrollToEndOfDocument(nil)
            }
        } else if pinned {
            nsView.scrollToEndOfDocument(nil)
        }
    }
}
