import AVFoundation
import Contacts
import Foundation
import JarvisCore
import MessageUI
import UIKit
import UserNotifications

@MainActor
enum DeviceTools {
    static let timerPrefix = "jarvis.timer."

    static func register(in registry: ToolRegistry, emergencyStop: EmergencyStop) throws {
        UIDevice.current.isBatteryMonitoringEnabled = true

        try registry.register(
            ToolSpec(
                name: "get_device_status",
                description: "Battery level and charging state, Low Power Mode, free storage and iPadOS version.",
                category: .device, risk: .safe, inputSchema: Schema.object([:])
            )
        ) { _ in
            let device = UIDevice.current
            let level = device.batteryLevel < 0 ? "unknown" : "\(Int(device.batteryLevel * 100))%"
            let state: String = switch device.batteryState {
            case .charging: "charging"
            case .full: "full"
            case .unplugged: "on battery"
            default: "unknown"
            }
            let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            let free = values?.volumeAvailableCapacityForImportantUsage.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "unknown"
            let text = """
            Battery: \(level), \(state)
            Low Power Mode: \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off")
            Free storage: \(free)
            \(device.model), \(device.systemName) \(device.systemVersion)
            """
            return ToolOutput(text, summary: "Battery \(level)")
        }

        try registry.register(
            ToolSpec(
                name: "start_timer",
                description: "Start a countdown timer. JARVIS notifies the user when it ends, even if the app is closed.",
                category: .device, risk: .safe,
                inputSchema: Schema.object([
                    "minutes": Schema.integer("Minutes (may be combined with seconds)"),
                    "seconds": Schema.integer("Seconds"),
                    "label": Schema.string("What the timer is for"),
                ])
            )
        ) { args in
            let total = (args.optionalInt("minutes") ?? 0) * 60 + (args.optionalInt("seconds") ?? 0)
            guard total > 0, total <= 24 * 3600 else { throw ToolError.invalidArguments("Timer must be between 1 second and 24 hours.") }
            let center = UNUserNotificationCenter.current()
            guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                throw ToolError.permissionDenied("Notifications are off for JARVIS, so the timer can't alert you. Allow them in Settings › Notifications › JARVIS.")
            }
            let content = UNMutableNotificationContent()
            content.title = "JARVIS timer"
            content.body = args.optionalString("label") ?? "Time's up."
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            let id = timerPrefix + UUID().uuidString
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(total), repeats: false)))
            let ends = Date().addingTimeInterval(TimeInterval(total))
            return ToolOutput("Timer set for \(total / 60) min \(total % 60) s, ending at \(Format.iso(ends)).", summary: "Timer started")
        }

        try registry.register(
            ToolSpec(
                name: "cancel_timers",
                description: "Cancel all running JARVIS timers.",
                category: .device, risk: .safe, inputSchema: Schema.object([:])
            )
        ) { _ in
            let count = await cancelAllTimers()
            return ToolOutput(count == 0 ? "No timers were running." : "Cancelled \(count) timer(s).", summary: "Timers cancelled")
        }

        // Queued JARVIS automations (timers) are part of the emergency stop.
        emergencyStop.register("Cancel JARVIS timers") {
            Task { await cancelAllTimers() }
        }
    }

    @discardableResult
    static func cancelAllTimers() async -> Int {
        let center = UNUserNotificationCenter.current()
        let ids = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(timerPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        return ids.count
    }
}

/// Messages, email, calls and contacts. iPadOS never lets an app send
/// a message or email on its own: JARVIS prepares it in Apple's composer and
/// the user taps Send. Calls go through the system's own call prompt.
@MainActor
enum CommunicationTools {
    static func register(in registry: ToolRegistry, presenter: Presenter) throws {
        try registry.register(
            ToolSpec(
                name: "find_contact",
                description: "Look up a contact by name and return their phone numbers and email addresses.",
                category: .communication, risk: .safe,
                inputSchema: Schema.object(["name": Schema.string("Name or nickname, e.g. 'Dad'")], required: ["name"])
            )
        ) { args in
            let store = CNContactStore()
            if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
                _ = try await store.requestAccess(for: .contacts)
            }
            let status = CNContactStore.authorizationStatus(for: .contacts)
            var allowed = status == .authorized
            if #available(iOS 18.0, *) { allowed = allowed || status == .limited }
            guard allowed else {
                throw ToolError.permissionDenied("JARVIS can't read Contacts. Allow it in Settings › Privacy & Security › Contacts.")
            }
            let keys: [CNKeyDescriptor] = [
                CNContactFormatter.descriptorForRequiredKeys(for: .fullName), CNContactNicknameKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor,
            ]
            let name = try args.string("name")
            var contacts = try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: keys)
            if contacts.isEmpty {
                // Relationship names like "Dad" are often stored as nicknames.
                let request = CNContactFetchRequest(keysToFetch: keys)
                try store.enumerateContacts(with: request) { contact, stop in
                    if contact.nickname.localizedCaseInsensitiveCompare(name) == .orderedSame { contacts.append(contact) }
                    if contacts.count >= 5 { stop.pointee = true }
                }
            }
            if contacts.isEmpty { return ToolOutput("No contact matches '\(name)'.", summary: "No contact") }
            let lines = contacts.prefix(5).map { contact -> String in
                let fullName = CNContactFormatter.string(from: contact, style: .fullName) ?? contact.nickname
                let phones = contact.phoneNumbers.map { "\(CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: $0.label ?? "")): \($0.value.stringValue)" }
                let emails = contact.emailAddresses.map { $0.value as String }
                return "- \(fullName)\(contact.nickname.isEmpty ? "" : " (\(contact.nickname))") | phones: \(phones.joined(separator: ", ")) | emails: \(emails.joined(separator: ", "))"
            }
            return ToolOutput(lines.joined(separator: "\n"), summary: "Found \(contacts.count) contact(s)")
        }

        try registry.register(
            ToolSpec(
                name: "send_message",
                description: "Send an iMessage/SMS. JARVIS asks the user to confirm, then opens Apple's Messages composer filled in; the user taps Send. Use find_contact first to get the number or email.",
                category: .communication, risk: .confirmationRequired,
                inputSchema: Schema.object([
                    "recipients": Schema.stringArray("Phone numbers or emails"),
                    "recipient_name": Schema.string("Who this is, for the confirmation card"),
                    "message": Schema.string("Message text"),
                ], required: ["recipients", "message"]),
                describe: { args in
                    ConfirmationDetails(
                        action: "Send message",
                        target: [args.optionalString("recipient_name"), args.stringArray("recipients").joined(separator: ", ")].compactMap { $0 }.joined(separator: " — "),
                        content: args.optionalString("message"), account: "Messages"
                    )
                }
            )
        ) { args in
            guard MFMessageComposeViewController.canSendText() else {
                throw ToolError.unavailable("This iPad can't send messages (Messages isn't set up).")
            }
            let outcome = await presenter.present(.message(recipients: args.stringArray("recipients"), body: try args.string("message")))
            switch outcome {
            case .sent: return ToolOutput("The user sent the message.", summary: "Message sent")
            case .failed: return ToolOutput.error("Messages reported that sending failed.")
            default: return ToolOutput("The user closed Messages without sending.", summary: "Not sent")
            }
        }

        try registry.register(
            ToolSpec(
                name: "send_email",
                description: "Send an email. JARVIS asks the user to confirm, then opens Apple's Mail composer filled in; the user taps Send.",
                category: .communication, risk: .confirmationRequired,
                inputSchema: Schema.object([
                    "to": Schema.stringArray("Email addresses"),
                    "subject": Schema.string("Subject"),
                    "body": Schema.string("Body text"),
                ], required: ["to", "subject", "body"]),
                describe: { args in
                    ConfirmationDetails(
                        action: "Send email", target: args.stringArray("to").joined(separator: ", "),
                        content: args.optionalString("body"), account: "Mail",
                        settings: [.init("Subject", args.optionalString("subject") ?? "")]
                    )
                }
            )
        ) { args in
            let to = args.stringArray("to"), subject = try args.string("subject"), body = try args.string("body")
            if MFMailComposeViewController.canSendMail() {
                let outcome = await presenter.present(.mail(to: to, subject: subject, body: body))
                switch outcome {
                case .sent: return ToolOutput("The user sent the email.", summary: "Email sent")
                case .saved: return ToolOutput("The user saved the email as a draft.", summary: "Draft saved")
                case .failed: return ToolOutput.error("Mail reported that sending failed.")
                default: return ToolOutput("The user closed Mail without sending.", summary: "Not sent")
                }
            }
            var components = URLComponents()
            components.scheme = "mailto"
            components.path = to.joined(separator: ",")
            components.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
            guard let url = components.url, await presenter.open(url) else {
                throw ToolError.unavailable("No mail app is set up on this iPad.")
            }
            return ToolOutput("Opened the default mail app with the draft. The user sends it from there.", summary: "Opened mail app")
        }

        try registry.register(
            ToolSpec(
                name: "start_call",
                description: "Start a phone or FaceTime call. The user confirms in JARVIS and again in the system call prompt. Phone calls on iPad route through a nearby iPhone (Continuity).",
                category: .communication, risk: .confirmationRequired,
                inputSchema: Schema.object([
                    "number_or_email": Schema.string("Phone number or FaceTime email"),
                    "recipient_name": Schema.string("Who is being called"),
                    "type": Schema.enumeration(["phone", "facetime", "facetime_audio"], "Call type"),
                ], required: ["number_or_email"]),
                describe: { args in
                    ConfirmationDetails(
                        action: "Call", target: [args.optionalString("recipient_name"), args.optionalString("number_or_email")].compactMap { $0 }.joined(separator: " — "),
                        settings: [.init("Type", args.optionalString("type") ?? "phone")]
                    )
                }
            )
        ) { args in
            let address = try args.string("number_or_email").filter { !$0.isWhitespace }
            let scheme = switch args.optionalString("type") ?? "phone" {
            case "facetime": "facetime"
            case "facetime_audio": "facetime-audio"
            default: "tel"
            }
            guard let url = URL(string: "\(scheme):\(address)"), await presenter.open(url) else {
                throw ToolError.unavailable("This iPad can't place that call.")
            }
            return ToolOutput("Handed the call to iPadOS; the system asks the user before dialling.", summary: "Call started")
        }
    }
}

/// Opening other apps through their public URL schemes, and running the
/// user's own Shortcuts. JARVIS never drives another app's UI.
@MainActor
enum AppLinkTools {
    static let apps: [String: String] = [
        "instagram": "instagram://app", "tiktok": "snssdk1233://", "youtube": "youtube://", "spotify": "spotify://",
        "maps": "maps://", "music": "music://", "photos": "photos-redirect://", "files": "shareddocuments://",
        "shortcuts": "shortcuts://", "facetime": "facetime://", "mail": "message://", "safari": "x-web-search://",
        "calendar": "calshow://", "reminders": "x-apple-reminderkit://", "notes": "mobilenotes://",
        "jarvis_settings": UIApplication.openSettingsURLString,
    ]

    static func register(in registry: ToolRegistry, presenter: Presenter) throws {
        try registry.register(
            ToolSpec(
                name: "open_app",
                description: "Open another app on the iPad. Apps: \(apps.keys.sorted().joined(separator: ", ")). 'jarvis_settings' opens JARVIS's page in the Settings app (permissions).",
                category: .device, risk: .safe,
                inputSchema: Schema.object(["app": Schema.enumeration(apps.keys.sorted(), "App to open")], required: ["app"])
            )
        ) { args in
            let app = try args.string("app")
            guard let link = apps[app], let url = URL(string: link) else { throw ToolError.invalidArguments("Unknown app.") }
            guard await presenter.open(url) else { throw ToolError.unavailable("\(app) isn't installed or can't be opened.") }
            return ToolOutput("Opened \(app).", summary: "Opened \(app)")
        }

        try registry.register(
            ToolSpec(
                name: "open_link",
                description: "Open a web page (https) in Safari for the user.",
                category: .web, risk: .safe,
                inputSchema: Schema.object(["url": Schema.string("https URL")], required: ["url"])
            )
        ) { args in
            guard let url = URL(string: try args.string("url")), url.scheme?.lowercased() == "https" else {
                throw ToolError.invalidArguments("Only https links can be opened.")
            }
            guard await presenter.open(url) else { throw ToolError.failed("Couldn't open the link.") }
            return ToolOutput("Opened \(url.host ?? "the page") in Safari.", summary: "Opened link")
        }

        try registry.register(
            ToolSpec(
                name: "run_shortcut",
                description: "Run one of the user's own Shortcuts by name (opens the Shortcuts app). Shortcuts can do many things, so the user confirms first.",
                category: .device, risk: .confirmationRequired,
                inputSchema: Schema.object(["name": Schema.string("Exact Shortcut name"), "input_text": Schema.string("Optional text input")], required: ["name"]),
                describe: { args in
                    ConfirmationDetails(action: "Run Shortcut", target: args.optionalString("name"), content: args.optionalString("input_text"), account: "Shortcuts")
                }
            )
        ) { args in
            var components = URLComponents(string: "shortcuts://run-shortcut")!
            components.queryItems = [URLQueryItem(name: "name", value: try args.string("name"))]
            if let text = args.optionalString("input_text") {
                components.queryItems?.append(URLQueryItem(name: "input", value: "text"))
                components.queryItems?.append(URLQueryItem(name: "text", value: text))
            }
            guard let url = components.url, await presenter.open(url) else { throw ToolError.unavailable("Couldn't open Shortcuts.") }
            return ToolOutput("Started the Shortcut in the Shortcuts app. JARVIS can't see what the Shortcut does after that.", summary: "Shortcut started")
        }
    }
}
