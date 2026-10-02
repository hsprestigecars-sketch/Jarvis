import Foundation
import Observation

/// User preferences. Non-secret values are in UserDefaults; the API key is in
/// the Keychain.
@MainActor
@Observable
final class JarvisSettings {
    private let defaults = UserDefaults.standard

    var apiKey: String
    var model: String
    var effort: String
    var webResearchEnabled: Bool
    var speakReplies: Bool
    var voiceIdentifier: String
    var confirmReminders: Bool
    var continuousConversation: Bool
    /// Listen for "Jarvis" while the app is open (on-device recognition only).
    var handsFree: Bool
    /// "auto" (Claude when a key is set, otherwise free on-device), "claude" or "onDevice".
    var brainChoice: String

    init() {
        let defaults = UserDefaults.standard
        apiKey = KeychainStore.get("anthropic_api_key") ?? ""
        model = defaults.string(forKey: "model") ?? "claude-opus-5-5"
        effort = defaults.string(forKey: "effort") ?? "medium"
        webResearchEnabled = defaults.object(forKey: "webResearch") as? Bool ?? true
        speakReplies = defaults.object(forKey: "speakReplies") as? Bool ?? true
        voiceIdentifier = defaults.string(forKey: "voice") ?? ""
        confirmReminders = defaults.object(forKey: "confirmReminders") as? Bool ?? false
        continuousConversation = defaults.object(forKey: "continuous") as? Bool ?? false
        handsFree = defaults.object(forKey: "handsFree") as? Bool ?? true
        brainChoice = defaults.string(forKey: "brain") ?? "auto"
    }

    /// Writes preferences to UserDefaults and the API key to the Keychain.
    func persist() {
        KeychainStore.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: "anthropic_api_key")
        defaults.set(model, forKey: "model")
        defaults.set(effort, forKey: "effort")
        defaults.set(webResearchEnabled, forKey: "webResearch")
        defaults.set(speakReplies, forKey: "speakReplies")
        defaults.set(voiceIdentifier, forKey: "voice")
        defaults.set(confirmReminders, forKey: "confirmReminders")
        defaults.set(continuousConversation, forKey: "continuous")
        defaults.set(handsFree, forKey: "handsFree")
        defaults.set(brainChoice, forKey: "brain")
    }

    var claudeConfiguration: ClaudeConfiguration {
        ClaudeConfiguration(apiKey: apiKey, model: model, effort: effort, webResearchEnabled: webResearchEnabled)
    }

    static let models = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-4-5"]
    static let efforts = ["low", "medium", "high", "xhigh"]
}
