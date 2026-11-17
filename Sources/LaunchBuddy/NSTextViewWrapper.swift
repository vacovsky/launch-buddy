import SwiftUI

struct NSTextViewWrapper: NSViewRepresentable {
    @Binding var text: String
    var pinned: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.drawsBackground = true
        textView.isRichText = false
        textView.autoresizingMask = []
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalRuler = false
        scrollView.hasVerticalRuler = false
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        let old = textView.string
        guard old != text else { return }

        let offset = nsView.contentView.bounds.origin

        if text.hasPrefix(old) {
            // Common case: new output appended to the end. Grow the text
            // storage in place so the existing lines keep their layout.
            // (Computed in UTF-16 units: NSRange and NSString.length are
            // UTF-16, so a grapheme-count drop would corrupt emoji output.)
            let oldUTF16 = (old as NSString).length
            let suffix = String(decoding: Array(text.utf16).dropFirst(oldUTF16),
                                as: UTF16.self)
            textView.textStorage?.replaceCharacters(
                in: NSRange(location: oldUTF16, length: 0),
                with: suffix)
        } else if old.hasSuffix(text) {
            // Scrollback trim: oldest lines were dropped from the front.
            // Remove the prefix in place instead of replacing everything.
            let dropLength = (old as NSString).length - (text as NSString).length
            textView.textStorage?.replaceCharacters(
                in: NSRange(location: 0, length: dropLength),
                with: "")
        } else {
            // New run or unexpected change: full replacement.
            textView.string = text
        }

        if pinned {
            textView.scrollToEndOfDocument(nil)
        } else {
            // Keep the user's scroll position stable across reflow.
            nsView.contentView.scroll(NSPoint(x: offset.x, y: offset.y))
        }
    }
}
