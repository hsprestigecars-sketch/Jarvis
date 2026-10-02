import CoreLocation
import EventKit
import Foundation

/// Calendar and Reminders through EventKit, Apple's supported framework.
/// JARVIS asks for access the first time a tool needs it.
@MainActor
final class EventKitService {
    static let shared = EventKitService()
    let store = EKEventStore()

    /// iPadOS 17 terminates an app that asks for full access without the
    /// matching Info.plist key. Swift Playgrounds packages can only declare the
    /// older keys, so in that build JARVIS uses the older request API instead.
    private static func hasInfoKey(_ key: String) -> Bool {
        Bundle.main.object(forInfoDictionaryKey: key) != nil
    }

    private func requestLegacyAccess(to type: EKEntityType) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            store.requestAccess(to: type) { granted, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: granted) }
            }
        }
    }

    func ensureEventAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return
        case .notDetermined:
            let granted: Bool
            if Self.hasInfoKey("NSCalendarsFullAccessUsageDescription") {
                granted = try await store.requestFullAccessToEvents()
            } else {
                granted = try await requestLegacyAccess(to: .event)
            }
            guard granted, EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                throw ToolError.permissionDenied("Calendar access was not granted. You can allow it in Settings › Privacy › Calendars.")
            }
        default:
            throw ToolError.permissionDenied("JARVIS does not have full Calendar access. Allow it in Settings › Privacy & Security › Calendars.")
        }
    }

    func ensureReminderAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return
        case .notDetermined:
            let granted: Bool
            if Self.hasInfoKey("NSRemindersFullAccessUsageDescription") {
                granted = try await store.requestFullAccessToReminders()
            } else {
                granted = try await requestLegacyAccess(to: .reminder)
            }
            guard granted, EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                throw ToolError.permissionDenied("Reminders access was not granted. You can allow it in Settings › Privacy › Reminders.")
            }
        default:
            throw ToolError.permissionDenied("JARVIS does not have Reminders access. Allow it in Settings › Privacy & Security › Reminders.")
        }
    }

    func reminders(matching predicate: NSPredicate) async -> [EKReminder] {
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }

    func reminder(id: String) -> EKReminder? {
        store.calendarItem(withIdentifier: id) as? EKReminder
    }
}

enum Format {
    static func dateTime(_ date: Date?) -> String {
        guard let date else { return "none" }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }

    static func iso(_ date: Date?) -> String {
        guard let date else { return "none" }
        return DateParsing.localISO(date)
    }

    static func recurrenceRule(_ value: String?) -> EKRecurrenceRule? {
        switch value?.lowercased() ?? "none" {
        case "daily": EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)
        case "weekly": EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)
        case "monthly": EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, end: nil)
        case "yearly": EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: nil)
        default: nil
        }
    }

    static let recurrenceValues = ["none", "daily", "weekly", "monthly", "yearly"]
}

@MainActor
enum CalendarTools {
    static var service: EventKitService { .shared }

    static func register(in registry: ToolRegistry) throws {
        try registry.register(
            ToolSpec(
                name: "list_calendar_events",
                description: "List calendar events between two times, optionally filtered by text. Use for 'what's on my calendar', briefings and planning.",
                category: .calendar, risk: .safe,
                inputSchema: Schema.object([
                    "start": Schema.string("ISO-8601 local start, e.g. 2026-10-03T00:00:00"),
                    "end": Schema.string("ISO-8601 local end"),
                    "query": Schema.string("Optional text to match in title, location or notes"),
                ], required: ["start", "end"]),
                returnsUntrustedContent: true
            )
        ) { args in
            try await service.ensureEventAccess()
            let start = try args.date("start"), end = try args.date("end")
            guard end > start else { throw ToolError.invalidArguments("end must be after start") }
            let predicate = service.store.predicateForEvents(withStart: start, end: end, calendars: nil)
            var events = service.store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
            if let query = args.optionalString("query")?.lowercased() {
                events = events.filter {
                    [$0.title, $0.location, $0.notes].compactMap { $0?.lowercased() }.contains { $0.contains(query) }
                }
            }
            if events.isEmpty { return ToolOutput("No events in that range.", summary: "No events") }
            let lines = events.prefix(100).map { event in
                var line = "- id: \(event.eventIdentifier ?? "?") | \(event.title ?? "Untitled") | "
                line += event.isAllDay ? "all day \(Format.iso(event.startDate).prefix(10))" : "\(Format.iso(event.startDate)) → \(Format.iso(event.endDate))"
                if let location = event.location, !location.isEmpty { line += " | at \(location)" }
                if event.hasRecurrenceRules { line += " | recurring" }
                line += " | calendar: \(event.calendar?.title ?? "?")"
                return line
            }
            return ToolOutput(lines.joined(separator: "\n"), summary: "Found \(events.count) event(s)")
        }

        try registry.register(
            ToolSpec(
                name: "find_free_time",
                description: "Find free time slots on a day between working hours, at least a minimum length.",
                category: .calendar, risk: .safe,
                inputSchema: Schema.object([
                    "date": Schema.string("Day as YYYY-MM-DD"),
                    "minimum_minutes": Schema.integer("Minimum slot length in minutes"),
                    "day_start": Schema.string("Earliest time HH:mm, default 08:00"),
                    "day_end": Schema.string("Latest time HH:mm, default 22:00"),
                ], required: ["date", "minimum_minutes"])
            )
        ) { args in
            try await service.ensureEventAccess()
            let day = try args.date("date")
            let minimum = TimeInterval(max(5, args.optionalInt("minimum_minutes") ?? 30) * 60)
            let calendar = Calendar.current
            func time(_ text: String?, _ fallback: Int) -> Date {
                let parts = (text ?? "").split(separator: ":").compactMap { Int($0) }
                let hour = parts.first ?? fallback, minute = parts.count > 1 ? parts[1] : 0
                return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
            }
            let windowStart = max(time(args.optionalString("day_start"), 8), calendar.isDateInToday(day) ? Date() : .distantPast)
            let windowEnd = time(args.optionalString("day_end"), 22)
            guard windowEnd > windowStart else { return ToolOutput("No time left in that window.", summary: "No free time") }
            let busy = service.store.events(matching: service.store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: nil))
                .filter { !$0.isAllDay && $0.availability != .free }
                .map { ($0.startDate!, $0.endDate!) }
                .sorted { $0.0 < $1.0 }
            var slots: [(Date, Date)] = []
            var cursor = windowStart
            for (start, end) in busy {
                if start.timeIntervalSince(cursor) >= minimum { slots.append((cursor, start)) }
                cursor = max(cursor, end)
            }
            if windowEnd.timeIntervalSince(cursor) >= minimum { slots.append((cursor, windowEnd)) }
            if slots.isEmpty { return ToolOutput("No free slot of that length.", summary: "No free time") }
            let text = slots.map { "- \(Format.iso($0.0)) → \(Format.iso($0.1)) (\(Int($0.1.timeIntervalSince($0.0) / 60)) min)" }
            return ToolOutput(text.joined(separator: "\n"), summary: "\(slots.count) free slot(s)")
        }

        try registry.register(
            ToolSpec(
                name: "create_calendar_event",
                description: "Create a calendar event. The user confirms before it is added.",
                category: .calendar, risk: .confirmationRequired,
                inputSchema: Schema.object([
                    "title": Schema.string("Event title"),
                    "start": Schema.string("ISO-8601 local start"),
                    "end": Schema.string("ISO-8601 local end; default one hour after start"),
                    "all_day": Schema.boolean("All-day event"),
                    "location": Schema.string("Location"),
                    "notes": Schema.string("Notes"),
                    "alert_minutes_before": Schema.integer("Alert this many minutes before"),
                    "recurrence": Schema.enumeration(Format.recurrenceValues, "Repeat rule"),
                ], required: ["title", "start"]),
                describe: { args in
                    var settings: [ConfirmationDetails.Setting] = [
                        .init("Starts", Format.dateTime(try? args.date("start"))),
                        .init("Ends", Format.dateTime((try? args.optionalDate("end")) ?? (try? args.date("start"))?.addingTimeInterval(3600))),
                    ]
                    if let location = args.optionalString("location") { settings.append(.init("Location", location)) }
                    if let alert = args.optionalInt("alert_minutes_before") { settings.append(.init("Alert", "\(alert) min before")) }
                    if let recurrence = args.optionalString("recurrence"), recurrence != "none" { settings.append(.init("Repeats", recurrence)) }
                    return ConfirmationDetails(
                        action: "Add calendar event", target: args.optionalString("title"),
                        content: args.optionalString("notes"), account: service.store.defaultCalendarForNewEvents?.title,
                        settings: settings
                    )
                }
            )
        ) { args in
            try await service.ensureEventAccess()
            let event = EKEvent(eventStore: service.store)
            event.title = try args.string("title")
            event.startDate = try args.date("start")
            event.endDate = try args.optionalDate("end") ?? event.startDate.addingTimeInterval(3600)
            event.isAllDay = args.optionalBool("all_day") ?? false
            event.location = args.optionalString("location")
            event.notes = args.optionalString("notes")
            if let minutes = args.optionalInt("alert_minutes_before") { event.addAlarm(EKAlarm(relativeOffset: TimeInterval(-minutes * 60))) }
            if let rule = Format.recurrenceRule(args.optionalString("recurrence")) { event.addRecurrenceRule(rule) }
            guard let calendar = service.store.defaultCalendarForNewEvents else { throw ToolError.unavailable("No default calendar is set.") }
            event.calendar = calendar
            try service.store.save(event, span: .futureEvents)
            return ToolOutput("Created event '\(event.title ?? "")' on \(Format.iso(event.startDate)) (id: \(event.eventIdentifier ?? "?")).", summary: "Event added")
        }

        try registry.register(
            ToolSpec(
                name: "update_calendar_event",
                description: "Change an existing calendar event (by id from list_calendar_events). Only fields provided are changed. The user confirms first.",
                category: .calendar, risk: .confirmationRequired,
                inputSchema: Schema.object([
                    "event_id": Schema.string("Event id"),
                    "title": Schema.string("New title"),
                    "start": Schema.string("New ISO-8601 start"),
                    "end": Schema.string("New ISO-8601 end"),
                    "location": Schema.string("New location"),
                    "notes": Schema.string("New notes"),
                ], required: ["event_id"]),
                describe: { args in
                    let event = args.optionalString("event_id").flatMap { service.store.event(withIdentifier: $0) }
                    var settings: [ConfirmationDetails.Setting] = []
                    if let title = args.optionalString("title") { settings.append(.init("New title", title)) }
                    if let start = try? args.optionalDate("start") { settings.append(.init("New start", Format.dateTime(start))) }
                    if let end = try? args.optionalDate("end") { settings.append(.init("New end", Format.dateTime(end))) }
                    if let location = args.optionalString("location") { settings.append(.init("New location", location)) }
                    return ConfirmationDetails(
                        action: "Change calendar event",
                        target: event.map { "\($0.title ?? "Untitled") — \(Format.dateTime($0.startDate))" } ?? "Unknown event",
                        content: args.optionalString("notes"), account: event?.calendar?.title, settings: settings
                    )
                }
            )
        ) { args in
            try await service.ensureEventAccess()
            guard let event = service.store.event(withIdentifier: try args.string("event_id")) else {
                throw ToolError.failed("No event with that id.")
            }
            if let title = args.optionalString("title") { event.title = title }
            if let start = try args.optionalDate("start") {
                let duration = event.endDate.timeIntervalSince(event.startDate)
                event.startDate = start
                event.endDate = start.addingTimeInterval(duration)
            }
            if let end = try args.optionalDate("end") { event.endDate = end }
            if let location = args.optionalString("location") { event.location = location }
            if let notes = args.optionalString("notes") { event.notes = notes }
            try service.store.save(event, span: .thisEvent)
            return ToolOutput("Updated '\(event.title ?? "")': \(Format.iso(event.startDate)) → \(Format.iso(event.endDate)).", summary: "Event updated")
        }

        try registry.register(
            ToolSpec(
                name: "delete_calendar_event",
                description: "Delete a calendar event by id. The user confirms first.",
                category: .calendar, risk: .confirmationRequired,
                inputSchema: Schema.object(["event_id": Schema.string("Event id")], required: ["event_id"]),
                describe: { args in
                    let event = args.optionalString("event_id").flatMap { service.store.event(withIdentifier: $0) }
                    return ConfirmationDetails(
                        action: "Delete calendar event",
                        target: event.map { "\($0.title ?? "Untitled") — \(Format.dateTime($0.startDate))" } ?? "Unknown event",
                        account: event?.calendar?.title
                    )
                }
            )
        ) { args in
            try await service.ensureEventAccess()
            guard let event = service.store.event(withIdentifier: try args.string("event_id")) else {
                throw ToolError.failed("No event with that id.")
            }
            let title = event.title ?? ""
            try service.store.remove(event, span: .thisEvent)
            return ToolOutput("Deleted '\(title)'.", summary: "Event deleted")
        }
    }
}

@MainActor
enum ReminderTools {
    static var service: EventKitService { .shared }

    static func register(in registry: ToolRegistry) throws {
        try registry.register(
            ToolSpec(
                name: "list_reminders",
                description: "List reminders. By default only incomplete ones.",
                category: .reminders, risk: .safe,
                inputSchema: Schema.object([
                    "include_completed": Schema.boolean("Include completed reminders from the last 7 days"),
                    "list_name": Schema.string("Only this Reminders list"),
                ]),
                returnsUntrustedContent: true
            )
        ) { args in
            try await service.ensureReminderAccess()
            var calendars = service.store.calendars(for: .reminder)
            if let name = args.optionalString("list_name") {
                calendars = calendars.filter { $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame }
                if calendars.isEmpty { throw ToolError.failed("No Reminders list named '\(name)'.") }
            }
            var reminders = await service.reminders(matching: service.store.predicateForIncompleteReminders(
                withDueDateStarting: nil, ending: nil, calendars: calendars))
            if args.optionalBool("include_completed") == true {
                reminders += await service.reminders(matching: service.store.predicateForCompletedReminders(
                    withCompletionDateStarting: Date().addingTimeInterval(-7 * 86400), ending: Date(), calendars: calendars))
            }
            if reminders.isEmpty { return ToolOutput("No reminders.", summary: "No reminders") }
            let lines = reminders.prefix(150).map { reminder -> String in
                let due = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
                var line = "- id: \(reminder.calendarItemIdentifier) | \(reminder.isCompleted ? "[done] " : "")\(reminder.title ?? "Untitled")"
                if let due { line += " | due \(Format.iso(due))" }
                if reminder.priority > 0 { line += " | priority \(reminder.priority)" }
                line += " | list: \(reminder.calendar?.title ?? "?")"
                return line
            }
            return ToolOutput(lines.joined(separator: "\n"), summary: "\(reminders.count) reminder(s)")
        }

        try registry.register(
            ToolSpec(
                name: "create_reminder",
                description: "Create a reminder in Apple Reminders, optionally due at a time, repeating, or triggered when arriving at or leaving a place.",
                category: .reminders, risk: .safe,
                inputSchema: Schema.object([
                    "title": Schema.string("What to remember"),
                    "due": Schema.string("ISO-8601 local due date/time; omit for no due date"),
                    "notes": Schema.string("Notes"),
                    "priority": Schema.enumeration(["none", "low", "medium", "high"], "Priority"),
                    "recurrence": Schema.enumeration(Format.recurrenceValues, "Repeat rule"),
                    "list_name": Schema.string("Reminders list; default list if omitted"),
                    "location_address": Schema.string("Address or place for a location-based reminder"),
                    "location_trigger": Schema.enumeration(["arriving", "leaving"], "When to fire the location reminder"),
                ], required: ["title"]),
                describe: { args in
                    ConfirmationDetails(
                        action: "Create reminder", target: args.optionalString("title"), content: args.optionalString("notes"),
                        settings: [.init("Due", Format.dateTime(try? args.optionalDate("due")))]
                    )
                }
            )
        ) { args in
            try await service.ensureReminderAccess()
            let reminder = EKReminder(eventStore: service.store)
            reminder.title = try args.string("title")
            reminder.notes = args.optionalString("notes")
            if let name = args.optionalString("list_name"),
               let list = service.store.calendars(for: .reminder).first(where: { $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                reminder.calendar = list
            } else {
                guard let list = service.store.defaultCalendarForNewReminders() else { throw ToolError.unavailable("No default Reminders list.") }
                reminder.calendar = list
            }
            if let due = try args.optionalDate("due") {
                reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
                reminder.addAlarm(EKAlarm(absoluteDate: due))
            }
            switch args.optionalString("priority") ?? "none" {
            case "high": reminder.priority = 1
            case "medium": reminder.priority = 5
            case "low": reminder.priority = 9
            default: break
            }
            if let rule = Format.recurrenceRule(args.optionalString("recurrence")) { reminder.addRecurrenceRule(rule) }
            var placeNote = ""
            if let address = args.optionalString("location_address") {
                let placemarks = try await CLGeocoder().geocodeAddressString(address)
                guard let placemark = placemarks.first, let location = placemark.location else {
                    throw ToolError.failed("Couldn't find the place '\(address)'.")
                }
                let structured = EKStructuredLocation(title: placemark.name ?? address)
                structured.geoLocation = location
                structured.radius = 150
                let alarm = EKAlarm()
                alarm.structuredLocation = structured
                alarm.proximity = args.optionalString("location_trigger") == "leaving" ? .leave : .enter
                reminder.addAlarm(alarm)
                placeNote = " It fires when \(alarm.proximity == .leave ? "leaving" : "arriving at") \(structured.title ?? address) (iPadOS needs Location access for Reminders)."
            }
            try service.store.save(reminder, commit: true)
            let due = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
            return ToolOutput(
                "Created reminder '\(reminder.title ?? "")'\(due.map { " due \(Format.iso($0))" } ?? "") in list '\(reminder.calendar.title)' (id: \(reminder.calendarItemIdentifier)).\(placeNote)",
                summary: "Reminder created"
            )
        }

        try registry.register(
            ToolSpec(
                name: "complete_reminder",
                description: "Mark a reminder as completed (id from list_reminders).",
                category: .reminders, risk: .safe,
                inputSchema: Schema.object(["reminder_id": Schema.string("Reminder id")], required: ["reminder_id"])
            )
        ) { args in
            try await service.ensureReminderAccess()
            guard let reminder = service.reminder(id: try args.string("reminder_id")) else { throw ToolError.failed("No reminder with that id.") }
            reminder.isCompleted = true
            try service.store.save(reminder, commit: true)
            return ToolOutput("Completed '\(reminder.title ?? "")'.", summary: "Reminder completed")
        }

        try registry.register(
            ToolSpec(
                name: "delete_reminder",
                description: "Delete a reminder (id from list_reminders). The user confirms first.",
                category: .reminders, risk: .confirmationRequired,
                inputSchema: Schema.object(["reminder_id": Schema.string("Reminder id")], required: ["reminder_id"]),
                describe: { args in
                    let reminder = args.optionalString("reminder_id").flatMap { service.reminder(id: $0) }
                    return ConfirmationDetails(action: "Delete reminder", target: reminder?.title ?? "Unknown reminder", account: reminder?.calendar?.title)
                }
            )
        ) { args in
            try await service.ensureReminderAccess()
            guard let reminder = service.reminder(id: try args.string("reminder_id")) else { throw ToolError.failed("No reminder with that id.") }
            let title = reminder.title ?? ""
            try service.store.remove(reminder, commit: true)
            return ToolOutput("Deleted reminder '\(title)'.", summary: "Reminder deleted")
        }
    }
}
