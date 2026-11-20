import EventKit
import Foundation

/// Shared EventKit access helper for Calendar tools.
enum CalendarAccessHelper {
    enum Result: Sendable {
        case granted
        case denied(String)
    }

    static func ensureFullAccess() async -> Result {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess:
            return .granted
        case .notDetermined:
            do {
                let store = EKEventStore()
                let granted = try await store.requestFullAccessToEvents()
                return granted
                    ? .granted
                    : .denied("Accès au Calendrier macOS refusé par l'utilisateur.")
            } catch {
                return .denied("Erreur lors de la demande d'accès au Calendrier : \(error.localizedDescription)")
            }
        case .writeOnly:
            return .denied("MacP dispose uniquement d'un accès en écriture au Calendrier. Activez l'accès complet dans Réglages Système > Confidentialité et sécurité > Calendriers.")
        case .denied, .restricted:
            return .denied("Accès au Calendrier macOS refusé ou restreint. Autorisez MacP dans Réglages Système > Confidentialité et sécurité > Calendriers.")
        @unknown default:
            return .denied("Statut d'autorisation EventKit inconnu.")
        }
    }

    static func parseISO8601(_ value: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: value) {
            return date
        }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        if let date = standard.date(from: value) {
            return date
        }

        // Also support local date-time without timezone suffix (e.g. "2026-11-20T14:30:00").
        let localFormatter = DateFormatter()
        localFormatter.locale = Locale(identifier: "en_US_POSIX")
        localFormatter.timeZone = .current
        localFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        if let date = localFormatter.date(from: value) {
            return date
        }

        localFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return localFormatter.date(from: value)
    }
}

/// Lists macOS Calendar events for today (or a requested date range) using native `EventKit`.
public struct CalendarEventsTool: MCPTool {
    public let name = "macos_list_calendar_events"
    public let displayName = "Lire Calendrier"
    public let shortSubtitle = "Événements EventKit"
    public let symbolName = "calendar"
    public let category: ToolCategory = .productivity
    public let description = "Lists macOS Calendar events for today or a specified date range using EventKit."
    public let sensitivity: ToolSensitivity = .sensitive
    public let permissionReason = "Un client IA souhaite consulter vos événements du Calendrier macOS."

    public init() {}

    public var annotations: MCPToolAnnotations {
        MCPToolAnnotations(
            title: "Lister les événements du Calendrier",
            readOnlyHint: true,
            destructiveHint: false,
            idempotentHint: true,
            openWorldHint: false
        )
    }

    public var inputSchema: JSONValue {
        [
            "type": "object",
            "properties": [
                "date": [
                    "type": "string",
                    "description": "Start date in YYYY-MM-DD format (local timezone). Defaults to today."
                ],
                "days": [
                    "type": "integer",
                    "description": "Number of days to include starting from 'date' (1 to 31). Defaults to 1 (today).",
                    "minimum": 1,
                    "maximum": 31
                ],
                "calendar_name": [
                    "type": "string",
                    "description": "Optional calendar title filter (case-insensitive)."
                ]
            ],
            "additionalProperties": false
        ]
    }

    public struct CalendarEventDTO: Sendable, Codable, Equatable {
        public let title: String
        public let calendar: String
        public let startDate: String
        public let endDate: String
        public let isAllDay: Bool
        public let location: String?
        public let notes: String?
    }

    private struct CalendarResponsePayload: Codable {
        let rangeStart: String
        let rangeEnd: String
        let count: Int
        let events: [CalendarEventDTO]
    }

    public func execute(arguments: [String: JSONValue]) async throws -> MCPCallToolResult {
        let days = min(max(arguments["days"]?.intValue ?? 1, 1), 31)
        let calendarFilter = arguments["calendar_name"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let startDate: Date
        if let dateStr = arguments["date"]?.stringValue, !dateStr.isEmpty {
            guard let parsed = Self.parseLocalDate(dateStr) else {
                return .failure("Format de date invalide : '\(dateStr)'. Utilisez YYYY-MM-DD (ex: 2026-11-20).")
            }
            startDate = parsed
        } else {
            startDate = Calendar.current.startOfDay(for: Date())
        }

        guard let endDate = Calendar.current.date(byAdding: .day, value: days, to: startDate) else {
            return .failure("Impossible de calculer la plage de dates demandée.")
        }

        switch await CalendarAccessHelper.ensureFullAccess() {
        case .granted:
            break
        case let .denied(message):
            return .failure(message)
        }

        let events = Self.fetchEvents(
            from: startDate,
            to: endDate,
            calendarFilter: (calendarFilter?.isEmpty == false) ? calendarFilter : nil
        )

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        let payload = CalendarResponsePayload(
            rangeStart: iso.string(from: startDate),
            rangeEnd: iso.string(from: endDate),
            count: events.count,
            events: events
        )

        return .success(try ToolOutputFormatter.encodeJSON(payload))
    }

    public static func parseLocalDate(_ string: String, calendar: Calendar = .current) -> Date? {
        let parts = string.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              (1...12).contains(month),
              (1...31).contains(day) else {
            return nil
        }

        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = 0
        components.minute = 0
        components.second = 0

        guard let date = calendar.date(from: components) else { return nil }
        let verified = calendar.dateComponents([.year, .month, .day], from: date)
        guard verified.year == year, verified.month == month, verified.day == day else {
            return nil
        }
        return date
    }

    private static func fetchEvents(
        from startDate: Date,
        to endDate: Date,
        calendarFilter: String?
    ) -> [CalendarEventDTO] {
        let store = EKEventStore()
        let calendars: [EKCalendar]?
        if let filter = calendarFilter {
            let matched = store.calendars(for: .event).filter {
                $0.title.localizedCaseInsensitiveCompare(filter) == .orderedSame
            }
            if matched.isEmpty {
                return []
            }
            calendars = matched
        } else {
            calendars = nil
        }

        let predicate = store.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: calendars
        )

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                let trimmedNotes: String?
                if let notes = event.notes, !notes.isEmpty {
                    trimmedNotes = notes.count > 500 ? String(notes.prefix(500)) + "..." : notes
                } else {
                    trimmedNotes = nil
                }

                return CalendarEventDTO(
                    title: event.title ?? "(Sans titre)",
                    calendar: event.calendar.title,
                    startDate: iso.string(from: event.startDate),
                    endDate: iso.string(from: event.endDate),
                    isAllDay: event.isAllDay,
                    location: (event.location?.isEmpty == false) ? event.location : nil,
                    notes: trimmedNotes
                )
            }
    }
}

/// Creates a new macOS Calendar event via native `EventKit`.
public struct CreateCalendarEventTool: MCPTool {
    public let name = "macos_create_calendar_event"
    public let displayName = "Créer Événement"
    public let shortSubtitle = "Ajouter au Calendrier"
    public let symbolName = "calendar.badge.plus"
    public let category: ToolCategory = .productivity
    public let description = "Creates a new event in the macOS Calendar app via EventKit."
    public let sensitivity: ToolSensitivity = .sensitive
    public let permissionReason = "Un client IA souhaite créer un nouvel événement dans votre Calendrier macOS."

    public init() {}

    public var annotations: MCPToolAnnotations {
        MCPToolAnnotations(
            title: "Créer un événement Calendrier",
            readOnlyHint: false,
            destructiveHint: false,
            idempotentHint: false,
            openWorldHint: false
        )
    }

    public var inputSchema: JSONValue {
        [
            "type": "object",
            "properties": [
                "title": [
                    "type": "string",
                    "description": "Title of the calendar event."
                ],
                "start_iso": [
                    "type": "string",
                    "description": "Start date/time in ISO-8601 format (e.g. '2026-11-21T14:00:00+01:00' or '2026-11-21T14:00')."
                ],
                "end_iso": [
                    "type": "string",
                    "description": "End date/time in ISO-8601 format. Defaults to 1 hour after start_iso."
                ],
                "calendar_name": [
                    "type": "string",
                    "description": "Optional target calendar title. Defaults to the default macOS calendar."
                ],
                "location": [
                    "type": "string",
                    "description": "Optional event location."
                ],
                "notes": [
                    "type": "string",
                    "description": "Optional notes/description."
                ],
                "is_all_day": [
                    "type": "boolean",
                    "description": "Set true for an all-day event (default: false)."
                ]
            ],
            "required": ["title", "start_iso"],
            "additionalProperties": false
        ]
    }

    private struct CreatedEventPayload: Codable {
        let created: Bool
        let eventIdentifier: String?
        let title: String
        let calendar: String
        let startDate: String
        let endDate: String
        let isAllDay: Bool
    }

    public func execute(arguments: [String: JSONValue]) async throws -> MCPCallToolResult {
        guard let title = arguments["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return .failure("Paramètre requis manquant : 'title' (String).")
        }

        guard let startStr = arguments["start_iso"]?.stringValue,
              let startDate = CalendarAccessHelper.parseISO8601(startStr) else {
            return .failure("Date 'start_iso' invalide. Utilisez un format ISO-8601 (ex: 2026-11-21T14:00:00+01:00).")
        }

        let endDate: Date
        if let endStr = arguments["end_iso"]?.stringValue, !endStr.isEmpty {
            guard let parsedEnd = CalendarAccessHelper.parseISO8601(endStr) else {
                return .failure("Date 'end_iso' invalide. Utilisez un format ISO-8601.")
            }
            guard parsedEnd >= startDate else {
                return .failure("'end_iso' doit être postérieure à 'start_iso'.")
            }
            endDate = parsedEnd
        } else {
            endDate = startDate.addingTimeInterval(3600)
        }

        let calendarName = arguments["calendar_name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let location = arguments["location"]?.stringValue
        let notes = arguments["notes"]?.stringValue
        let isAllDay = arguments["is_all_day"]?.boolValue ?? false

        switch await CalendarAccessHelper.ensureFullAccess() {
        case .granted:
            break
        case let .denied(message):
            return .failure(message)
        }

        let store = EKEventStore()
        let targetCalendar: EKCalendar?
        if let calendarName, !calendarName.isEmpty {
            targetCalendar = store.calendars(for: .event).first {
                $0.title.localizedCaseInsensitiveCompare(calendarName) == .orderedSame && $0.allowsContentModifications
            }
            if targetCalendar == nil {
                return .failure("Calendrier modifiable introuvable : '\(calendarName)'.")
            }
        } else {
            targetCalendar = store.defaultCalendarForNewEvents
        }

        guard let resolvedCalendar = targetCalendar else {
            return .failure("Aucun calendrier par défaut disponible pour créer un événement.")
        }

        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.isAllDay = isAllDay
        event.calendar = resolvedCalendar
        if let location, !location.isEmpty { event.location = location }
        if let notes, !notes.isEmpty { event.notes = notes }

        try store.save(event, span: .thisEvent, commit: true)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        let payload = CreatedEventPayload(
            created: true,
            eventIdentifier: event.eventIdentifier,
            title: title,
            calendar: resolvedCalendar.title,
            startDate: iso.string(from: startDate),
            endDate: iso.string(from: endDate),
            isAllDay: isAllDay
        )
        return .success(try ToolOutputFormatter.encodeJSON(payload))
    }
}
