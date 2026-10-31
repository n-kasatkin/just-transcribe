import Foundation

/// Whether ostt can transcribe: a model is selected and, for a cloud provider, its key is saved.
public enum EngineReadiness: Sendable, Equatable {
    case ready(OsttModelID)
    /// `ostt model current` printed "No model selected." or could not run.
    case noModel
    case missingKey(OsttModelID)

    public init(current: OsttModelID?, providersWithKeys: Set<String>) {
        guard let current else {
            self = .noModel
            return
        }
        self = SettingsState.currentModelMissingKey(current, providersWithKeys: providersWithKeys)
            ? .missingKey(current) : .ready(current)
    }

    public var isReady: Bool {
        if case .ready = self { true } else { false }
    }
}

/// The onboarding window's four checks.
public struct OnboardingStatus: Sendable, Equatable {
    public var microphone: MicrophoneAccess
    public var accessibility: Bool
    public var hasShortcut: Bool
    public var engine: EngineReadiness

    public init(microphone: MicrophoneAccess, accessibility: Bool, hasShortcut: Bool, engine: EngineReadiness) {
        self.microphone = microphone
        self.accessibility = accessibility
        self.hasShortcut = hasShortcut
        self.engine = engine
    }

    /// What is not set yet, in row order.
    public var missing: [String] {
        var missing: [String] = []
        if microphone != .granted { missing.append("microphone access") }
        if !accessibility { missing.append("Accessibility") }
        if !hasShortcut { missing.append("a shortcut") }
        if !engine.isReady { missing.append(engine == .noModel ? "a model" : "an API key") }
        return missing
    }

    public var isComplete: Bool { missing.isEmpty }

    /// The line beside Done.
    public var summary: String {
        let missing = missing
        guard let last = missing.last else { return "You're all set." }
        let list = missing.count == 1 ? last : missing.dropLast().joined(separator: ", ") + " and " + last
        return "Still missing: \(list). You can finish later in Settings."
    }
}

public enum Onboarding {
    /// Set only when the user presses Done.
    public static let completedKey = "onboardingCompleted"
    /// The provider the "Paste an API key" picker starts on.
    public static let defaultKeyProvider = "elevenlabs"

    public static func shouldShowAtLaunch(_ defaults: UserDefaults) -> Bool {
        !defaults.bool(forKey: completedKey)
    }

    /// The model to select once a key for `provider` is saved: ostt lists each provider's recommended
    /// model first. Nil when a model of that provider is already selected, so the user's choice stays.
    public static func modelAfterSavingKey(provider: String, current: OsttModelID?, models: [OsttModel]) -> OsttModelID? {
        guard current?.provider != provider else { return nil }
        return models.first { $0.id.provider == provider }?.id
    }
}
