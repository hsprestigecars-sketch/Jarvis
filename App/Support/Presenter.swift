import Foundation
import Observation
import UIKit

/// Lets tools hand off to system UI (Messages composer, Mail composer, Share
/// Sheet) and wait for the real outcome. iPadOS never lets an app send a
/// message or email silently, so the user always sees and sends it themselves.
@MainActor
@Observable
final class Presenter {
    enum Sheet: Identifiable {
        case message(recipients: [String], body: String)
        case mail(to: [String], subject: String, body: String)
        case share(items: [Any])

        var id: String {
            switch self {
            case .message: "message"
            case .mail: "mail"
            case .share: "share"
            }
        }
    }

    enum Outcome: Equatable {
        case sent, saved, cancelled, failed, completed, dismissed
    }

    var sheet: Sheet?
    @ObservationIgnored private var continuation: CheckedContinuation<Outcome, Never>?

    func present(_ sheet: Sheet) async -> Outcome {
        finish(.dismissed)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.sheet = sheet
        }
    }

    func finish(_ outcome: Outcome) {
        sheet = nil
        continuation?.resume(returning: outcome)
        continuation = nil
    }

    func open(_ url: URL) async -> Bool {
        await UIApplication.shared.open(url)
    }
}
