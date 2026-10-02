import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var keyDraft = ""

    var body: some View {
        @Bindable var settings = model.settings
        NavigationStack {
            Form {
                Section {
                    SecureField("sk-ant-…", text: $keyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(model.settings.apiKey.isEmpty ? "Save key" : "Replace key") {
                        model.settings.apiKey = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        model.settings.persist()
                        keyDraft = ""
                    }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    if !model.settings.apiKey.isEmpty {
                        Label("Key stored in the Keychain on this iPad", systemImage: "key.fill").foregroundStyle(.green)
                        Button("Remove key", role: .destructive) {
                            model.settings.apiKey = ""
                            model.settings.persist()
                        }
                    }
                } header: {
                    Text("Claude API key")
                } footer: {
                    Text("Create a key at console.anthropic.com. It is kept in the iPad Keychain and only sent to api.anthropic.com.")
                }

                Section("Reasoning") {
                    Picker("Model", selection: $settings.model) {
                        ForEach(JarvisSettings.models, id: \.self) { Text($0) }
                    }
                    Picker("Effort", selection: $settings.effort) {
                        ForEach(JarvisSettings.efforts, id: \.self) { Text($0.capitalized) }
                    }
                    Toggle("Web research (search & fetch)", isOn: $settings.webResearchEnabled)
                }

                Section {
                    Toggle("Speak replies to voice requests", isOn: $settings.speakReplies)
                    Toggle("Keep listening after replies", isOn: $settings.continuousConversation)
                    Picker("Voice", selection: $settings.voiceIdentifier) {
                        Text("Default (English UK)").tag("")
                        ForEach(VoiceOutput.availableVoices, id: \.identifier) { voice in
                            Text("\(voice.name) (\(voice.language))").tag(voice.identifier)
                        }
                    }
                } header: {
                    Text("Voice")
                } footer: {
                    Text("Speech is recognised on the iPad when supported. The microphone is only on while you talk to JARVIS. Say “Hey Siri, ask JARVIS” or “Talk to JARVIS” to start hands-free.")
                }

                Section {
                    Toggle("Confirm before creating reminders", isOn: $settings.confirmReminders)
                        .onChange(of: model.settings.confirmReminders) { _, _ in model.applySafetyPreferences() }
                    NavigationLink("Tools and safety levels") { ToolListView() }
                    NavigationLink("Permanently blocked") { BlockedListView() }
                } header: {
                    Text("Safety")
                } footer: {
                    Text("Sending, publishing, deleting and calendar changes always ask first. Financial, password and authentication-code actions are blocked in code and can't be enabled.")
                }

                Section {
                    Button("Open iPad Settings for JARVIS") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                } header: {
                    Text("Permissions")
                } footer: {
                    Text("Calendars, Reminders, Contacts, Photos, Camera, Microphone and Speech are requested only when first needed.")
                }

                Section {
                    ForEach(SocialPlatform.allCases, id: \.self) { platform in
                        LabeledContent(platform.displayName, value: SocialAndMediaTools.connectors[platform] == nil ? "Not connected" : "Connected")
                    }
                } header: {
                    Text("Social accounts")
                } footer: {
                    Text("Publishing uses the official Instagram Graph API and TikTok Content Posting API with OAuth sign-in on the platform's own page — JARVIS never asks for passwords or codes. Until a developer app is registered and connected, JARVIS prepares posts and hands them to the official apps.")
                }

                Section {
                    LabeledContent("Mac companion", value: "Not paired")
                } header: {
                    Text("Devices")
                } footer: {
                    Text("A future JARVIS Mac companion will pair explicitly and every Mac action will still pass JARVIS safety and confirmation.")
                }

                if !model.registrationProblems.isEmpty {
                    Section("Startup problems") {
                        ForEach(model.registrationProblems, id: \.self) { Text($0).foregroundStyle(.red) }
                    }
                }

                Section {
                    Button("Clear conversation", role: .destructive) { model.agent.clearConversation() }
                }
            }
            .navigationTitle("JARVIS Settings")
            .onDisappear {
                model.settings.persist()
                model.applySafetyPreferences()
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

private struct ToolListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            ForEach([RiskLevel.safe, .confirmationRequired], id: \.self) { level in
                Section(level == .safe ? "Level 1 — runs immediately" : "Level 2 — asks you first") {
                    ForEach(model.agent.registry.specs.filter { effectiveRisk($0) == level }, id: \.name) { spec in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(spec.name).font(.body.monospaced())
                            Text(spec.description).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Built in") {
                Text("web_search, web_fetch — read-only research run by Anthropic. Page content is treated as untrusted data.").font(.caption)
            }
        }
        .navigationTitle("Tools")
    }

    private func effectiveRisk(_ spec: ToolSpec) -> RiskLevel {
        model.agent.safety.alwaysConfirm.contains(spec.name) ? .confirmationRequired : spec.risk
    }
}

private struct BlockedListView: View {
    private let items = [
        "Banking and bank transfers", "Credit and debit cards", "Payments and financial transfers",
        "Stock and investment trading, brokerage accounts", "Cryptocurrency wallets, transfers and private keys",
        "Passwords and saved credentials", "One-time, 2FA, verification and recovery codes",
        "Business banking, payment and financial systems", "Sensitive customer databases, important contracts and financial records",
    ]

    var body: some View {
        List {
            Section {
                ForEach(items, id: \.self) { Label($0, systemImage: "lock.shield.fill") }
            } footer: {
                Text("Enforced in code: no tool for these can be registered, every tool argument is scanned for card numbers, bank details, keys, passwords and codes, financial apps and sites can't be opened, and such requests are refused before they reach Claude. Research and explanations about these topics are still allowed.")
            }
        }
        .navigationTitle("Permanently blocked")
    }
}
