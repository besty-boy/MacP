import AppKit
import MacPCore
import SwiftUI

/// Two-pane local Audit Log & JSON Payload Inspector window with search, outcome filtering, and JSON/CSV export.
struct AuditLogSheetView: View {
    let appState: AppState

    @State private var searchText = ""
    @State private var outcomeFilter: OutcomeFilter = .all
    @State private var selectedEntryID: UUID?

    private enum OutcomeFilter: String, CaseIterable, Identifiable {
        case all = "Tous"
        case success = "Succès"
        case denied = "Refusés"
        case error = "Erreurs"

        var id: String { rawValue }
    }

    private var filteredEntries: [AuditEntry] {
        appState.allEntries.filter { entry in
            switch outcomeFilter {
            case .all: break
            case .success: if entry.outcome != .success { return false }
            case .denied: if entry.outcome != .denied { return false }
            case .error: if entry.outcome != .error { return false }
            }

            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return true }

            return (entry.toolName ?? "").localizedCaseInsensitiveContains(trimmed)
                || entry.clientName.localizedCaseInsensitiveContains(trimmed)
                || entry.method.localizedCaseInsensitiveContains(trimmed)
                || entry.argumentsSummary.localizedCaseInsensitiveContains(trimmed)
                || entry.detail.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var selectedEntry: AuditEntry? {
        if let id = selectedEntryID, let match = filteredEntries.first(where: { $0.id == id }) {
            return match
        }
        return filteredEntries.first
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top Toolbar
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Rechercher un outil, client, URI ou détail...", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                Picker("Filtre", selection: $outcomeFilter) {
                    ForEach(OutcomeFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)

                Menu {
                    Button("Exporter en JSON...") {
                        appState.exportAuditLog(asCSV: false)
                    }
                    Button("Exporter en CSV...") {
                        appState.exportAuditLog(asCSV: true)
                    }
                } label: {
                    Label("Exporter", systemImage: "square.and.arrow.up")
                }
                .controlSize(.small)
                .disabled(appState.allEntries.isEmpty)
            }
            .padding(14)

            Divider()

            if filteredEntries.isEmpty {
                ContentUnavailableView(
                    "Aucune entrée dans le journal",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Toutes les invocations d'outils et ressources MCP sont consignées localement dans audit.jsonl.")
                )
            } else {
                HSplitView {
                    // Left List
                    List(filteredEntries, selection: $selectedEntryID) { entry in
                        AuditSummaryRow(entry: entry)
                            .tag(entry.id)
                    }
                    .listStyle(.inset)
                    .frame(minWidth: 300, idealWidth: 340)

                    // Right Payload Inspector
                    if let entry = selectedEntry {
                        AuditPayloadInspector(entry: entry)
                            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView(
                            "Sélectionnez une requête",
                            systemImage: "doc.plaintext"
                        )
                        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }

            Divider()

            // Footer
            HStack {
                Text("\(filteredEntries.count) entrée(s) • \(appState.auditLogger.logFileURL.path)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button("Révéler dans le Finder") {
                    appState.revealAuditLogInFinder()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Effacer", role: .destructive) {
                    appState.clearAuditLog()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(appState.allEntries.isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(.regularMaterial)
    }
}

private struct AuditSummaryRow: View {
    let entry: AuditEntry

    private var badgeColor: Color {
        switch entry.outcome {
        case .success: return .green
        case .denied: return .orange
        case .error: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(badgeColor)
                    .frame(width: 7, height: 7)
                Text(entry.toolName ?? entry.method)
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text("\(entry.durationMs) ms")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text(entry.clientName)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct AuditPayloadInspector: View {
    let entry: AuditEntry

    private var outcomeLabel: String {
        switch entry.outcome {
        case .success: return "Succès"
        case .denied: return "Refusé"
        case .error: return "Erreur"
        }
    }

    private var outcomeColor: Color {
        switch entry.outcome {
        case .success: return .green
        case .denied: return .orange
        case .error: return .red
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.toolName ?? entry.method)
                            .font(.system(.headline, design: .monospaced, weight: .semibold))
                        Text("\(entry.clientName) • \(entry.method) • \(entry.timestamp.formatted(date: .abbreviated, time: .standard))")
                            .font(.system(.caption))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(outcomeLabel) • \(entry.durationMs) ms")
                        .font(.system(.caption, weight: .semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(outcomeColor.opacity(0.16), in: Capsule())
                        .foregroundStyle(outcomeColor)
                }

                InspectorCodeBlock(
                    title: "Arguments JSON",
                    content: entry.argumentsJSON ?? entry.argumentsSummary
                )

                InspectorCodeBlock(
                    title: "Résultat / Détail",
                    content: entry.resultPreview ?? entry.detail
                )
            }
            .padding(16)
        }
    }
}

private struct InspectorCodeBlock: View {
    let title: String
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(content, forType: .string)
                } label: {
                    Label("Copier", systemImage: "doc.on.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }

            Text(content.isEmpty ? "(vide)" : content)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}
