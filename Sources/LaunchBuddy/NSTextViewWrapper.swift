import SwiftUI
import AppKit

/// An NSTextView that keeps its width pinned to the enclosing clip view.
///
/// A bare NSTextView used as a scroll view's document view is never sized by
/// the hosting environment: SwiftUI sets the scroll view's frame in a single
/// pass, so no resize delta ever reaches the document view, and it keeps its
/// zero initial width (it may still grow vertically to fit content). With
/// widthTracksTextView the text container then collapses to
/// (clipWidth - 2 x inset) pt, which is negative at zero width, glyph layout
/// degenerates, and nothing is drawn — the text sits in the storage yet is
/// invisible. viewDidMoveToWindow covers initial placement; layout() covers
/// every later window resize.
final class WidthTrackingTextView: NSTextView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncWidthToClipView()
    }

    override func layout() {
        super.layout()
        syncWidthToClipView()
    }

    func syncWidthToClipView() {
        guard let clip = enclosingScrollView?.contentView else { return }
        let clipWidth = clip.bounds.width
        guard clipWidth > 0, abs(frame.width - clipWidth) > 0.5 else { return }
        setFrameSize(NSSize(width: clipWidth, height: frame.height))
    }
}

/// Attributes stamped on text inserted through the incremental storage
/// path. A plain `replaceCharacters(in:with:)` insert creates runs with no
/// attributes, which NSLayoutManager draws in a fixed default color —
/// black — so output stays unreadable in a dark-appearance window. Stamping
/// the font and the *dynamic* text color keeps runs correct in both
/// appearances (the dynamic color re-resolves when the appearance flips).
private let insertedRunAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
    .foregroundColor: NSColor.textColor,
]

struct NSTextViewWrapper: NSViewRepresentable {
    @Binding var text: String
    var pinned: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = WidthTrackingTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.drawsBackground = true
        textView.isRichText = false
        // Standard scrollable-document configuration: the width follows the
        // clip view, the height grows with the content.
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

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
        // Last-resort width sync: if no layout pass has run yet (or it ran
        // before the clip view had its final size), the document view can
        // still be zero-width and the text invisible.
        (textView as? WidthTrackingTextView)?.syncWidthToClipView()

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
            let insertedLength = (suffix as NSString).length
            if insertedLength > 0 {
                textView.textStorage?.setAttributes(
                    insertedRunAttributes,
                    range: NSRange(location: oldUTF16, length: insertedLength))
            }
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
            // setString: applies the typing attributes; stamp explicitly so
            // the whole-replacement path matches the incremental one.
            let fullLength = (text as NSString).length
            if fullLength > 0 {
                textView.textStorage?.setAttributes(
                    insertedRunAttributes,
                    range: NSRange(location: 0, length: fullLength))
            }
        }

        if pinned {
            textView.scrollToEndOfDocument(nil)
        } else {
            // Keep the user's scroll position stable across reflow.
            nsView.contentView.scroll(NSPoint(x: offset.x, y: offset.y))
        }
    }
}
