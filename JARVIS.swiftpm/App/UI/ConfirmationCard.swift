import SwiftUI

/// WAITING FOR CONFIRMATION card. Shows exactly what will run; confirming
/// passes the card's fingerprint so only this exact action can execute.
struct ConfirmationCard: View {
    let action: PendingAction
    let engine: ConfirmationEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "hand.raised.fill")
                Text("WAITING FOR CONFIRMATION").font(.caption.weight(.heavy))
                Spacer()
                Text(action.details.risk.label).font(.caption2.weight(.bold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.amber.opacity(0.2), in: Capsule())
            }
            .foregroundStyle(Theme.amber)

            field("Action", action.details.action, prominent: true)
            if let target = action.details.target, !target.isEmpty { field("Target", target) }
            if let account = action.details.account, !account.isEmpty { field("Account", account) }
            if let content = action.details.content, !content.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Content").font(.caption).foregroundStyle(Theme.textSecondary)
                    ScrollView {
                        Text(content).font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }
                    .frame(maxHeight: 180)
                    .padding(10)
                    .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            ForEach(action.details.settings, id: \.name) { setting in
                field(setting.name, setting.value)
            }

            HStack(spacing: 12) {
                Button(role: .cancel) {
                    engine.cancel(id: action.id)
                } label: {
                    Text("CANCEL").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .tint(Theme.textSecondary)
                .keyboardShortcut(.escape, modifiers: [])

                Button {
                    engine.confirm(id: action.id, fingerprint: action.fingerprint)
                } label: {
                    Text("CONFIRM").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.amber)
            }
            Text("Say “Confirm” or “Cancel”.").font(.caption2).foregroundStyle(Theme.textSecondary)
        }
        .padding(16)
        .background(Theme.amber.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.amber.opacity(0.6), lineWidth: 1.5))
        .foregroundStyle(Theme.textPrimary)
    }

    private func field(_ name: String, _ value: String, prominent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.caption).foregroundStyle(Theme.textSecondary)
            Text(value).font(prominent ? .title3.weight(.semibold) : .body).textSelection(.enabled)
        }
    }
}
