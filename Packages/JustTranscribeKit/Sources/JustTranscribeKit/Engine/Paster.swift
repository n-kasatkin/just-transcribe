import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Puts text on the pasteboard and, when allowed, sends ⌘V by key code so any keyboard layout works.
/// The text stays on the pasteboard either way.
public struct Paster: Sendable {
    public enum Outcome: Sendable, Equatable {
        case pasted
        /// Accessibility is not granted, Secure Input is on, or the pasteboard write failed, so nothing
        /// was typed.
        case copiedOnly
    }

    /// Returns false when the text did not land on the pasteboard.
    public var writePasteboard: @MainActor @Sendable (String) -> Bool
    public var isAccessibilityTrusted: @MainActor @Sendable () -> Bool
    public var isSecureInputEnabled: @MainActor @Sendable () -> Bool
    public var sendPasteKeystroke: @MainActor @Sendable () -> Void
    /// Lets the pasteboard change reach the target app before the keystroke.
    public var keystrokeDelay: Duration

    public init(
        writePasteboard: @escaping @MainActor @Sendable (String) -> Bool = Paster.writeGeneralPasteboard,
        isAccessibilityTrusted: @escaping @MainActor @Sendable () -> Bool = { AXIsProcessTrusted() },
        isSecureInputEnabled: @escaping @MainActor @Sendable () -> Bool = { IsSecureEventInputEnabled() },
        sendPasteKeystroke: @escaping @MainActor @Sendable () -> Void = Paster.postCommandV,
        keystrokeDelay: Duration = .milliseconds(50)
    ) {
        self.writePasteboard = writePasteboard
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.isSecureInputEnabled = isSecureInputEnabled
        self.sendPasteKeystroke = sendPasteKeystroke
        self.keystrokeDelay = keystrokeDelay
    }

    @MainActor
    public func paste(_ text: String) async -> Outcome {
        // A failed write would make ⌘V paste whatever was copied before.
        guard writePasteboard(text), isAccessibilityTrusted(), !isSecureInputEnabled() else { return .copiedOnly }
        try? await Task.sleep(for: keystrokeDelay)
        // Secure Input may have turned on during the delay (focus moved to a password field).
        guard !isSecureInputEnabled() else { return .copiedOnly }
        sendPasteKeystroke()
        return .pasted
    }

    @MainActor
    public static func writeGeneralPasteboard(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }

    @MainActor
    public static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}
