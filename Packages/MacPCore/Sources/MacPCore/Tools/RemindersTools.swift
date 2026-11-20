import EventKit
import Foundation

enum RemindersAccessHelper {
    enum Result: Sendable {
        case granted
        case denied(String)
    }

    static func ensureFullAccess() async -> Result {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        switch status {
        case .fullAccess:
            return .granted
        case .notDetermined:
            do {
                let store = EKEventStore()
                let granted = try await store.requestFullAccessToReminders()
                return granted
                    ? .granted
                    : .denied("Accès aux Rappels macOS refusé par l'utilisateur.")
            } catch {
                return .denied("Erreur lors de la demande d'accès aux Rappels : \(error.localizedDescription)")
            }
        case .writeOnly:
            return .denied("Accès complet requis pour les Rappels dans Réglages Système > Confidentialité et sécurité > Rappels.")
        case .denied, .restricted:
            return .denied("Accès aux Rappels macOS refusé ou restreint. Autorisez MacP dans Réglages Système > Confidentialité et sécurité > Rappels.")
        @unknown default:
            return .denied("Statut d'autorisation EventKit (Rappels) inconnu.")
        }
    }
}

/// Lists macOS Reminders via native `EventKit`.
public struct ListRemindersTool: MCPTool {
    public let name = "macos_list_reminders"
    public let displayName = "Lire Rappels"
    public let shortSubtitle = "Tâches EventKit"
    public let symbolName = "checklist"
    public let category: ToolCategory = .productivity
    public let description = "Lists macOS Reminders (incomplete by default, or filtered by list name) using EventKit."
    public let sensitivity: ToolSensitivity = .sensitive
    public let permissionReason = "Un client IA souhaite lire vos listes de Rappels macOS."

    public init() {}

    public var annotations: MCPToolAnnotations {
        MCPToolAnnotations(
            title: "Lister les Rappels macOS",
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
                "list_name": [
                    "type": "string",
                    "description": "Optional reminder list title filter (case-insensitive)."
                ],
                "include_completed": [
                    "type": "boolean",
                    "description": "Whether to include completed reminders (default: false)."
                ],
                "limit": [
                    "type": "integer",
                    "description": "Maximum number of reminders to return (1 to 200, default: 50).",
                    "minimum": 1,
                    "maximum": 200
                ]
            ],
            "additionalProperties": false
        ]
    }

    public struct ReminderDTO: Sendable, Codable {
        public let id: String
        public let title: String
        public let list: String
        public let isCompleted: Bool
        public let priority: Int
        public let dueDate: String?
        public let notes: String?
    }

    private struct ListPayload: Codable {
        let count: Int
        let lists: [String]
        let reminders: [ReminderDTO]
    }

    public func execute(arguments: [String: JSONValue]) async throws -> MCPCallToolResult {
        let includeCompleted = arguments["include_completed"]?.boolValue ?? false
        let limit = min(max(arguments["limit"]?.intValue ?? 50, 1), 200)
        let listFilter = arguments["list_name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)

        switch await RemindersAccessHelper.ensureFullAccess() {
        case .granted:
            break
        case let .denied(message):
            return .failure(message)
        }

        let payload = await Self.fetchReminders(
            listFilter: (listFilter?.isEmpty == false) ? listFilter : nil,
            includeCompleted: includeCompleted,
            limit: limit
        )
        return .success(try ToolOutputFormatter.encodeJSON(payload))
    }

    private static func fetchReminders(
        listFilter: String?,
        includeCompleted: Bool,
        limit: Int
    ) async -> ListPayload {
        await withCheckedContinuation { continuation in
            let store = EKEventStore()
            let allLists = store.calendars(for: .reminder)
            let allListNames = allLists.map(\.title).sorted()

            let targetCalendars: [EKCalendar]?
            if let listFilter {
                let matched = allLists.filter {
                    $0.title.localizedCaseInsensitiveCompare(listFilter) == .orderedSame
                }
                if matched.isEmpty {
                    continuation.resume(returning: ListPayload(count: 0, lists: allListNames, reminders: []))
                    return
                }
                targetCalendars = matched
            } else {
                targetCalendars = nil
            }

            let predicate: NSPredicate = includeCompleted
                ? store.predicateForReminders(in: targetCalendars)
                : store.predicateForIncompleteReminders(
                    withDueDateStarting: nil,
                    ending: nil,
                    calendars: targetCalendars
                )

            store.fetchReminders(matching: predicate) { fetched in
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime]

                let items = (fetched ?? [])
                    .prefix(limit)
                    .map { reminder in
                        let dueStr = reminder.dueDateComponents?.date.map { iso.string(from: $0) }
                        let trimmedNotes: String?
                        if let notes = reminder.notes, !notes.isEmpty {
                            trimmedNotes = notes.count > 300 ? String(notes.prefix(300)) + "..." : notes
                        } else {
                            trimmedNotes = nil
                        }

                        return ReminderDTO(
                            id: reminder.calendarItemIdentifier,
                            title: reminder.title ?? "(Sans titre)",
                            list: reminder.calendar.title,
                            isCompleted: reminder.isCompleted,
                            priority: reminder.priority,
                            dueDate: dueStr,
                            notes: trimmedNotes
                        )
                    }

                continuation.resume(returning: ListPayload(
                    count: items.count,
                    lists: allListNames,
                    reminders: items
                ))
            }
        }
    }
}

/// Creates a new macOS Reminder via native `EventKit`.
public struct CreateReminderTool: MCPTool {
    public let name = "macos_create_reminder"
    public let displayName = "Créer Rappel"
    public let shortSubtitle = "Ajouter une tâche"
    public let symbolName = "checklist.checked"
    public let category: ToolCategory = .productivity
    public let description = "Creates a new reminder in macOS Reminders via EventKit."
    public let sensitivity: ToolSensitivity = .sensitive
    public let permissionReason = "Un client IA souhaite créer un nouveau Rappel sur votre Mac."

    public init() {}

    public var annotations: MCPToolAnnotations {
        MCPToolAnnotations(
            title: "Créer un Rappel",
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
                    "description": "Title of the reminder."
                ],
                "list_name": [
                    "type": "string",
                    "description": "Optional reminder list name. Defaults to the default Reminders list."
                ],
                "due_iso": [
                    "type": "string",
                    "description": "Optional due date/time in ISO-8601 format."
                ],
                "notes": [
                    "type": "string",
                    "description": "Optional notes for the reminder."
                ],
                "priority": [
                    "type": "integer",
                    "description": "Optional priority (0 = none, 1 = high, 5 = medium, 9 = low).",
                    "minimum": 0,
                    "maximum": 9
                ]
            ],
            "required": ["title"],
            "additionalProperties": false
        ]
    }

    private struct CreatedPayload: Codable {
        let created: Bool
        let id: String
        let title: String
        let list: String
        let dueDate: String?
    }

    public func execute(arguments: [String: JSONValue]) async throws -> MCPCallToolResult {
        guard let title = arguments["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return .failure("Paramètre requis manquant : 'title' (String).")
        }

        let listName = arguments["list_name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = arguments["notes"]?.stringValue
        let priority = arguments["priority"]?.intValue ?? 0

        var dueDate: Date?
        if let dueStr = arguments["due_iso"]?.stringValue, !dueStr.isEmpty {
            guard let parsed = CalendarAccessHelper.parseISO8601(dueStr) else {
                return .failure("Format 'due_iso' invalide. Utilisez un format ISO-8601 (ex: 2026-11-21T09:00:00+01:00).")
            }
            dueDate = parsed
        }

        switch await RemindersAccessHelper.ensureFullAccess() {
        case .granted:
            break
        case let .denied(message):
            return .failure(message)
        }

        let store = EKEventStore()
        let targetList: EKCalendar?
        if let listName, !listName.isEmpty {
            targetList = store.calendars(for: .reminder).first {
                $0.title.localizedCaseInsensitiveCompare(listName) == .orderedSame
            }
            if targetList == nil {
                return .failure("Liste de Rappels introuvable : '\(listName)'.")
            }
        } else {
            targetList = store.defaultCalendarForNewReminders()
        }

        guard let resolvedList = targetList else {
            return .failure("Aucune liste de Rappels par défaut disponible.")
        }

        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = resolvedList
        reminder.priority = priority
        if let notes, !notes.isEmpty { reminder.notes = notes }
        if let dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: dueDate
            )
        }

        try store.save(reminder, commit: true)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        let payload = CreatedPayload(
            created: true,
            id: reminder.calendarItemIdentifier,
            title: title,
            list: resolvedList.title,
            dueDate: dueDate.map { iso.string(from: $0) }
        )
        return .success(try ToolOutputFormatter.encodeJSON(payload))
    }
}

/// Marks a macOS Reminder as completed by identifier or title via `EventKit`.
public struct CompleteReminderTool: MCPTool {
    public let name = "macos_complete_reminder"
    public let displayName = "Compléter Rappel"
    public let shortSubtitle = "Cocher une tâche"
    public let symbolName = "checkmark.circle"
    public let category: ToolCategory = .productivity
    public let description = "Marks an incomplete macOS Reminder as completed by its 'reminder_id' or exact 'title'."
    public let sensitivity: ToolSensitivity = .sensitive
    public let permissionReason = "Un client IA souhaite marquer un Rappel macOS comme terminé."

    public init() {}

    public var annotations: MCPToolAnnotations {
        MCPToolAnnotations(
            title: "Terminer un Rappel",
            readOnlyHint: false,
            destructiveHint: false,
            idempotentHint: true,
            openWorldHint: false
        )
    }

    public var inputSchema: JSONValue {
        [
            "type": "object",
            "properties": [
                "reminder_id": [
                    "type": "string",
                    "description": "Identifier returned by macos_list_reminders."
                ],
                "title": [
                    "type": "string",
                    "description": "Exact title of the incomplete reminder (used if reminder_id is omitted)."
                ]
            ],
            "additionalProperties": false
        ]
    }

    private struct CompletedPayload: Codable {
        let completed: Bool
        let id: String
        let title: String
        let list: String
    }

    public func execute(arguments: [String: JSONValue]) async throws -> MCPCallToolResult {
        let reminderID = arguments["reminder_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = arguments["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard (reminderID?.isEmpty == false) || (title?.isEmpty == false) else {
            return .failure("Fournissez soit 'reminder_id' soit 'title'.")
        }

        switch await RemindersAccessHelper.ensureFullAccess() {
        case .granted:
            break
        case let .denied(message):
            return .failure(message)
        }

        let outcome: Result<CompletedPayload, Error> = await withCheckedContinuation { continuation in
            let store = EKEventStore()
            let predicate = store.predicateForIncompleteReminders(
                withDueDateStarting: nil,
                ending: nil,
                calendars: nil
            )
            store.fetchReminders(matching: predicate) { fetched in
                let match = (fetched ?? []).first { reminder in
                    if let reminderID, !reminderID.isEmpty {
                        return reminder.calendarItemIdentifier == reminderID
                    }
                    if let title, !title.isEmpty {
                        return (reminder.title ?? "").localizedCaseInsensitiveCompare(title) == .orderedSame
                    }
                    return false
                }

                guard let target = match else {
                    continuation.resume(returning: .failure(NSError(
                        domain: "MacP.Reminders",
                        code: 404,
                        userInfo: [NSLocalizedDescriptionKey: "Rappel incomplet introuvable."]
                    )))
                    return
                }

                target.isCompleted = true
                target.completionDate = Date()
                do {
                    try store.save(target, commit: true)
                    continuation.resume(returning: .success(CompletedPayload(
                        completed: true,
                        id: target.calendarItemIdentifier,
                        title: target.title ?? "(Sans titre)",
                        list: target.calendar.title
                    )))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }

        switch outcome {
        case let .success(payload):
            return .success(try ToolOutputFormatter.encodeJSON(payload))
        case let .failure(error):
            return .failure(error.localizedDescription)
        }
    }
}
