import Foundation
import Testing
@testable import JustTranscribeKit

struct OnboardingStateTests {
    private let scribe = OsttModelID(provider: "elevenlabs", model: "scribe_v2")
    private let turbo = OsttModelID(provider: "whisper", model: "turbo-q5_0")
    private let script = OsttModelID(provider: "command", model: "my-script")

    @Test func engineNeedsASelectedModel() {
        #expect(EngineReadiness(current: nil, providersWithKeys: ["elevenlabs"]) == .noModel)
        // "No model selected." parses to no model.
        #expect(OsttOutput.currentModel("No model selected.\n") == nil)
    }

    @Test func cloudEngineNeedsItsKey() {
        #expect(EngineReadiness(current: scribe, providersWithKeys: []) == .missingKey(scribe))
        #expect(EngineReadiness(current: scribe, providersWithKeys: ["openai"]) == .missingKey(scribe))
        #expect(EngineReadiness(current: scribe, providersWithKeys: ["elevenlabs"]) == .ready(scribe))
    }

    @Test func localAndExternalEnginesNeedNoKey() {
        #expect(EngineReadiness(current: turbo, providersWithKeys: []).isReady)
        #expect(EngineReadiness(current: script, providersWithKeys: []).isReady)
        #expect(!EngineReadiness.noModel.isReady)
        #expect(!EngineReadiness.missingKey(scribe).isReady)
    }

    @Test func completeStatusSaysSo() {
        let status = OnboardingStatus(microphone: .granted, accessibility: true, hasShortcut: true, engine: .ready(turbo))
        #expect(status.isComplete)
        #expect(status.missing.isEmpty)
        #expect(status.summary == "You're all set.")
    }

    @Test func summaryListsWhatIsMissingInRowOrder() {
        let none = OnboardingStatus(microphone: .notDetermined, accessibility: false, hasShortcut: false, engine: .noModel)
        #expect(!none.isComplete)
        #expect(none.missing == ["microphone access", "Accessibility", "a shortcut", "a model"])
        #expect(none.summary == "Still missing: microphone access, Accessibility, a shortcut and a model. You can finish later in Settings.")

        let one = OnboardingStatus(microphone: .denied, accessibility: true, hasShortcut: true, engine: .ready(turbo))
        #expect(one.summary == "Still missing: microphone access. You can finish later in Settings.")

        let key = OnboardingStatus(microphone: .granted, accessibility: true, hasShortcut: false, engine: .missingKey(scribe))
        #expect(key.summary == "Still missing: a shortcut and an API key. You can finish later in Settings.")
    }

    @Test func showsAtLaunchUntilDone() throws {
        let suite = "OnboardingStateTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(Onboarding.shouldShowAtLaunch(defaults))
        defaults.set(true, forKey: Onboarding.completedKey)
        #expect(!Onboarding.shouldShowAtLaunch(defaults))
    }

    @Test func onlyTheFirstDoneCountsAsFirstCompletion() throws {
        let suite = "OnboardingStateTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(Onboarding.complete(defaults))
        #expect(!Onboarding.shouldShowAtLaunch(defaults))
        #expect(!Onboarding.complete(defaults))
    }

    @Test func keyPickerStartsOnTheSelectedCloudProviderElseElevenLabs() {
        #expect(OsttProvider.withID(Onboarding.defaultKeyProvider)?.needsKey == true)
        #expect(Onboarding.keyProvider(current: nil) == "elevenlabs")
        #expect(Onboarding.keyProvider(current: turbo) == "elevenlabs")
        #expect(Onboarding.keyProvider(current: script) == "elevenlabs")
        #expect(Onboarding.keyProvider(current: OsttModelID("openai/gpt-transcribe")) == "openai")
    }

    @Test func savingAKeySelectsTheProvidersFirstModel() {
        let models = [
            OsttModel(id: scribe, name: "Scribe v2 (general purpose)", installed: nil, active: false),
            OsttModel(id: OsttModelID(provider: "elevenlabs", model: "scribe_v2_medical"), name: "Scribe v2 Medical",
                      installed: nil, active: false),
        ]
        #expect(Onboarding.modelAfterSavingKey(provider: "elevenlabs", current: nil, models: models) == scribe)
        #expect(Onboarding.modelAfterSavingKey(provider: "elevenlabs", current: turbo, models: models) == scribe)
        #expect(Onboarding.modelAfterSavingKey(provider: "elevenlabs", current: OsttModelID("elevenlabs/scribe_v2_medical"),
                                               models: models) == nil)
        #expect(Onboarding.modelAfterSavingKey(provider: "elevenlabs", current: nil, models: []) == nil)
        #expect(Onboarding.modelAfterSavingKey(provider: "openai", current: nil, models: models) == nil)
    }
}
