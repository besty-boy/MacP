import Foundation

/// Live macOS MCP Resources (`macos://...`) backed by the registered tools and governed by the same
/// Shield Mode, tool enable toggles, and permission policies.
public struct MCPResourceCatalog: Sendable {
    public struct Entry: Sendable {
        public let definition: MCPResourceDefinition
        public let backingToolName: String
        public let defaultArguments: [String: JSONValue]
    }

    public let entries: [Entry]
    private let byURI: [String: Entry]

    public init(entries: [Entry] = MCPResourceCatalog.defaultEntries) {
        self.entries = entries
        self.byURI = Dictionary(uniqueKeysWithValues: entries.map { ($0.definition.uri, $0) })
    }

    public static let defaultEntries: [Entry] = [
        Entry(
            definition: MCPResourceDefinition(
                uri: "macos://system/stats",
                name: "Statistiques système macOS",
                description: "CPU, RAM, batterie, disque, état thermique et uptime en temps réel.",
                mimeType: "application/json"
            ),
            backingToolName: "macos_system_stats",
            defaultArguments: [:]
        ),
        Entry(
            definition: MCPResourceDefinition(
                uri: "macos://apps/running",
                name: "Applications ouvertes",
                description: "Applications macOS en cours d'exécution et application au premier plan.",
                mimeType: "application/json"
            ),
            backingToolName: "macos_list_running_apps",
            defaultArguments: [:]
        ),
        Entry(
            definition: MCPResourceDefinition(
                uri: "macos://shortcuts/list",
                name: "Raccourcis macOS installés",
                description: "Liste des Raccourcis macOS prêts à être exécutés.",
                mimeType: "application/json"
            ),
            backingToolName: "macos_list_shortcuts",
            defaultArguments: [:]
        ),
        Entry(
            definition: MCPResourceDefinition(
                uri: "macos://clipboard/current",
                name: "Presse-papiers actuel",
                description: "Texte actuellement présent dans le presse-papiers macOS.",
                mimeType: "application/json"
            ),
            backingToolName: "macos_read_clipboard",
            defaultArguments: [:]
        ),
        Entry(
            definition: MCPResourceDefinition(
                uri: "macos://calendar/today",
                name: "Agenda du jour",
                description: "Événements du Calendrier macOS pour la journée en cours.",
                mimeType: "application/json"
            ),
            backingToolName: "macos_list_calendar_events",
            defaultArguments: ["days": 1]
        ),
        Entry(
            definition: MCPResourceDefinition(
                uri: "macos://reminders/open",
                name: "Rappels en cours",
                description: "Tâches non terminées dans l'app Rappels macOS.",
                mimeType: "application/json"
            ),
            backingToolName: "macos_list_reminders",
            defaultArguments: ["include_completed": false]
        )
    ]

    public func entry(forURI uri: String) -> Entry? {
        byURI[uri]
    }

    public func definitions(enabledUsing settings: ToolSettingsStore, registry: MCPToolRegistry) -> [MCPResourceDefinition] {
        guard !settings.isShieldModeActive else { return [] }
        return entries
            .filter { entry in
                registry.tool(named: entry.backingToolName) != nil
                    && settings.isToolEnabled(entry.backingToolName)
            }
            .map(\.definition)
    }
}

/// Built-in MCP Prompts exposing curated macOS workflows directly to Antigravity, Claude Desktop, and Cursor.
public struct MCPPromptCatalog: Sendable {
    public init() {}

    public var definitions: [MCPPromptDefinition] {
        [
            MCPPromptDefinition(
                name: "daily_briefing",
                description: "Génère un briefing quotidien complet à partir du Calendrier, des Rappels et de l'état matériel du Mac.",
                arguments: [
                    MCPPromptArgument(
                        name: "days",
                        description: "Nombre de jours d'agenda à couvrir (défaut : 1).",
                        required: false
                    )
                ]
            ),
            MCPPromptDefinition(
                name: "focus_mode_setup",
                description: "Prépare le Mac pour une session de travail concentrée (apps ouvertes, raccourci Focus, audio, notification).",
                arguments: [
                    MCPPromptArgument(
                        name: "goal",
                        description: "Objectif de la session de focus (ex: 'Coder MacP pendant 90 min').",
                        required: true
                    )
                ]
            ),
            MCPPromptDefinition(
                name: "clipboard_assistant",
                description: "Lit le presse-papiers macOS, applique une transformation demandée et recopie le résultat proprement.",
                arguments: [
                    MCPPromptArgument(
                        name: "task",
                        description: "Transformation souhaitée (ex: 'résumer', 'corriger', 'traduire en anglais').",
                        required: false
                    )
                ]
            ),
            MCPPromptDefinition(
                name: "screen_troubleshooter",
                description: "Capture la fenêtre active et analyse ce qui est affiché à l'écran pour diagnostiquer un problème.",
                arguments: [
                    MCPPromptArgument(
                        name: "question",
                        description: "Question précise sur ce qui est visible à l'écran.",
                        required: false
                    )
                ]
            )
        ]
    }

    public func getPrompt(name: String, arguments: [String: String]) -> MCPGetPromptResult? {
        switch name {
        case "daily_briefing":
            let days = arguments["days"] ?? "1"
            return MCPGetPromptResult(
                description: "Briefing quotidien macOS (Agenda + Rappels + Santé du Mac)",
                messages: [
                    MCPPromptMessage(
                        role: "user",
                        content: .text("""
                        Prépare-moi un briefing quotidien clair et structuré en utilisant les outils MacP :
                        1. Appelle `macos_list_calendar_events` (days: \(days)) pour mes rendez-vous.
                        2. Appelle `macos_list_reminders` (include_completed: false) pour mes tâches prioritaires.
                        3. Appelle `macos_system_stats` pour vérifier batterie, RAM et espace disque.
                        Synthétise le tout en 3 blocs concis : Agenda, Priorités du jour, et État du Mac.
                        """)
                    )
                ]
            )

        case "focus_mode_setup":
            let goal = arguments["goal"] ?? "travail concentré"
            return MCPGetPromptResult(
                description: "Préparation d'une session Focus sur macOS",
                messages: [
                    MCPPromptMessage(
                        role: "user",
                        content: .text("""
                        Aide-moi à préparer mon Mac pour cette session : « \(goal) ».
                        1. Liste les applications ouvertes (`macos_list_running_apps`) et les Raccourcis disponibles (`macos_list_shortcuts`).
                        2. Propose un plan rapide (lancer un raccourci Focus s'il existe, ajuster le volume/mode sombre via `macos_system_controls`, créer un rappel de fin de session).
                        3. Une fois prêt, envoie une notification macOS de confirmation (`macos_send_notification`).
                        """)
                    )
                ]
            )

        case "clipboard_assistant":
            let task = arguments["task"] ?? "nettoyer, structurer et améliorer le texte"
            return MCPGetPromptResult(
                description: "Assistant intelligent du presse-papiers macOS",
                messages: [
                    MCPPromptMessage(
                        role: "user",
                        content: .text("""
                        1. Lis mon presse-papiers actuel avec `macos_read_clipboard`.
                        2. Applique la transformation suivante : \(task).
                        3. Affiche le résultat et propose de le copier directement dans le presse-papiers avec `macos_write_clipboard`.
                        """)
                    )
                ]
            )

        case "screen_troubleshooter":
            let question = arguments["question"] ?? "Explique ce qui est affiché et aide-moi à résoudre l'erreur ou améliorer ce que tu vois."
            return MCPGetPromptResult(
                description: "Analyse visuelle de la fenêtre active",
                messages: [
                    MCPPromptMessage(
                        role: "user",
                        content: .text("""
                        1. Vérifie l'application active avec `macos_list_running_apps`.
                        2. Capture la fenêtre active avec `macos_capture_screen` (target: "frontmost_window").
                        3. Réponds précisément à ma demande : \(question)
                        """)
                    )
                ]
            )

        default:
            return nil
        }
    }
}
