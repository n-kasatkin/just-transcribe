import AppKit

/// What the pill shows.
enum PillState: Equatable {
    /// Bars follow `PillController.setLevel(_:)`.
    case recording
    /// A hump crawls across the bars.
    case transcribing
    /// Red bars and a label of at most three words; hides itself after 2 s.
    case error(String)
    /// A short white label such as "Nothing heard" or "Copied"; hides itself after 1.2 s.
    case notice(String)
}

/// The floating pill at the top center of the screen. It never takes focus or mouse events.
@MainActor
final class PillController {
    private static let height: CGFloat = 32
    private static let padding: CGFloat = 14
    private static let barsWidth: CGFloat = 34

    private var panel: NSPanel?
    private var bars: LevelBars?
    private var animation: Task<Void, Never>?
    private var autoHide: Task<Void, Never>?

    /// Shows `state` in a new panel: a panel created earlier does not appear on full-screen
    /// spaces that opened after it.
    func show(_ state: PillState) {
        let previousLevel = bars?.level ?? 0
        hide()
        let bars = LevelBars(frame: NSRect(x: Self.padding, y: 8, width: Self.barsWidth, height: 16))
        bars.level = state == .recording ? previousLevel : 0
        bars.crawl = state == .transcribing
        let label: NSTextField?
        switch state {
        case .recording, .transcribing:
            label = nil
        case .error(let message):
            bars.color = .systemRed
            label = Self.label(Self.firstWords(message))
        case .notice(let message):
            label = Self.label(message)
        }

        let panel = Self.makePanel(bars: bars, label: label)
        let screen = NSScreen.main?.visibleFrame ?? .zero
        panel.setFrameOrigin(NSPoint(x: screen.midX - panel.frame.width / 2, y: screen.maxY - panel.frame.height - 12))
        panel.orderFrontRegardless()
        self.panel = panel
        self.bars = bars

        // Weak, so a released controller's task ends instead of redrawing an invisible view.
        animation = Task { [weak bars] in
            while !Task.isCancelled, let bars {
                bars.needsDisplay = true
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
        switch state {
        case .error: hide(after: .seconds(2))
        case .notice: hide(after: .milliseconds(1200))
        case .recording, .transcribing: break
        }
    }

    /// The microphone level in 0...1; used while recording.
    func setLevel(_ level: Double) {
        bars?.level = CGFloat(level)
    }

    func hide() {
        animation?.cancel()
        animation = nil
        autoHide?.cancel()
        autoHide = nil
        panel?.orderOut(nil)
        panel = nil
        bars = nil
    }

    private func hide(after delay: Duration) {
        autoHide = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private static func firstWords(_ message: String) -> String {
        message.split(whereSeparator: \.isWhitespace).prefix(3).joined(separator: " ")
    }

    private static func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.sizeToFit()
        return label
    }

    private static func makePanel(bars: LevelBars, label: NSTextField?) -> NSPanel {
        var width = padding + barsWidth + padding
        if let label {
            let labelWidth = min(label.frame.width, 240)
            label.frame = NSRect(
                x: padding + barsWidth + 8, y: (height - label.frame.height) / 2,
                width: labelWidth, height: label.frame.height
            )
            width += 8 + labelWidth
        }
        let size = NSSize(width: width, height: height)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.level = .screenSaver // above every app window, full-screen ones included
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let background = NSView(frame: NSRect(origin: .zero, size: size))
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.85).cgColor
        background.layer?.cornerRadius = height / 2
        background.addSubview(bars)
        if let label { background.addSubview(label) }
        panel.contentView = background
        return panel
    }
}
