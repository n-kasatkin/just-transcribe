import AppKit

/// A window with the bundled THIRD_PARTY_NOTICES.md as selectable monospaced text. The file is
/// about 330 KB, so it is read only when the window first opens, and the text view lays out only
/// what scrolls into view.
final class AcknowledgementsWindowController {
    private var window: NSWindow?

    private static let intro = """
        just transcribe is built on ostt by Kristofer Lund (MIT). ostt transcribes with \
        transcribe.cpp and ggml (MIT). The shortcut recorder is KeyboardShortcuts by Sindre Sorhus \
        (MIT). The offline models are Whisper by OpenAI (MIT) and Parakeet by NVIDIA (CC-BY-4.0). \
        The full notices follow.


        """

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.textStorage?.setAttributedString(Self.text())

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: true
        )
        window.title = "Acknowledgements"
        window.contentView = scrollView
        window.contentMinSize = NSSize(width: 420, height: 300)
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private static func text() -> NSAttributedString {
        let notices = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? "THIRD_PARTY_NOTICES.md is missing from the app bundle."
        let text = NSMutableAttributedString(string: intro, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor,
        ])
        text.append(NSAttributedString(string: notices, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]))
        return text
    }
}
