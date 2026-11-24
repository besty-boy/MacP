import MacPCore
import SwiftUI

/// Main Menu Bar Popover Dashboard: Liquid Glass aesthetic, Bento Grid telemetry,
/// categorized tools with token-economy presets & granular governance, 1-click AI client configurator, and live Activity Feed.
struct DashboardView: View {
    let appState: AppState
    @Environment(\.openWindow) private var openWindow

    @State private var selectedTab: DashboardTab = .overview
    @State private var selectedCategory: ToolCategory? = nil
    @State private var toolSearchText = ""

    private enum DashboardTab: String, CaseIterable, Identifiable {
        case overview = "Aperçu"
        case tools = "Outils"
        case clients = "Clients"

        var id: String { rawValue }
    }

    private var filteredTools: [MCPToolMetadata] {
        appState.tools.filter { tool in
            if let category = selectedCategory, tool.category != category {
                return false
            }
            let query = toolSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return true }
            return tool.displayName.localizedCaseInsensitiveContains(query)
                || tool.shortSubtitle.localizedCaseInsensitiveContains(query)
                || tool.name.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusHeaderView(
                snapshot: appState.snapshot,
                isShieldActive: appState.isShieldModeActive,
                onToggleShield: { appState.setShieldMode($0) }
            )

            // Shield Mode Active Banner
            if appState.isShieldModeActive {
                HStack(spacing: 8) {
                    Image(systemName: "shield.slash.fill")
                        .foregroundStyle(.orange)
                    Text("Mode Bouclier actif — toutes les requêtes IA sont bloquées.")
                        .font(.system(.caption, weight: .medium))
                        .foregroundStyle(.primary)
                    Spacer()
                    Button("Réactiver") {
                        appState.setShieldMode(false)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.mini)
                }
                .padding(10)
                .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if let errorMessage = appState.snapshot.lastError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.system(.caption))
                        .lineLimit(2)
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            // Segmented Navigation Bar
            Picker("Section", selection: $selectedTab) {
                Text("Aperçu").tag(DashboardTab.overview)
                Text("Outils (\(appState.activeToolsCount)/\(appState.tools.count))").tag(DashboardTab.tools)
                Text("Clients").tag(DashboardTab.clients)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: selectedTab) { _, newValue in
                appState.setOverviewTabSelected(newValue == .overview)
            }

            // Active Tab Content
            switch selectedTab {
            case .overview:
                overviewContent
            case .tools:
                toolsContent
            case .clients:
                ClientsSettingsView(appState: appState)
            }

            // Persistent Footer Bar
            HStack(spacing: 8) {
                Button {
                    appState.copyMCPConfigToClipboard()
                } label: {
                    Label(
                        appState.copiedConfigFeedback ? "Config copiée" : "Copier JSON",
                        systemImage: appState.copiedConfigFeedback ? "checkmark" : "doc.on.doc"
                    )
                    .font(.system(.caption, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    openAuditInspector(selecting: nil)
                } label: {
                    Label("Journal", systemImage: "doc.text.magnifyingglass")
                        .font(.system(.caption, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button("Quitter") {
                    appState.quitApp()
                }
                .buttonStyle(.plain)
                .font(.system(.caption, weight: .medium))
                .foregroundStyle(.secondary)
                .keyboardShortcut("q", modifiers: .command)
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(width: 448)
        .background(.regularMaterial)
    }

    private func openAuditInspector(selecting entryID: UUID?) {
        if let entryID {
            appState.selectedAuditEntryID = entryID
        }
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "audit-log")
    }

    // MARK: - Overview Tab

    private var overviewContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            TelemetryBentoGrid(
                stats: appState.liveTelemetry,
                snapshot: appState.snapshot,
                activeToolsCount: appState.activeToolsCount,
                totalToolsCount: appState.tools.count,
                resourcesCount: appState.enabledResourcesCount,
                promptsCount: appState.promptsCount,
                estimatedContextTokens: appState.estimatedContextTokens
            )

            ActivityFeedCard(
                entries: appState.recentEntries,
                onOpenFullLog: { openAuditInspector(selecting: nil) },
                onSelectEntry: { entry in openAuditInspector(selecting: entry.id) }
            )
        }
    }

    // MARK: - Tools Tab

    private var toolsContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Token-Economy Preset Bar + Live Context Cost
            HStack(spacing: 6) {
                ForEach(ToolPreset.allCases) { preset in
                    let isActive = (appState.activePreset == preset)
                    Button {
                        appState.applyPreset(preset)
                    } label: {
                        Text(preset.frenchTitle)
                            .font(.system(size: 10.5, weight: isActive ? .semibold : .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(
                                isActive ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05),
                                in: Capsule()
                            )
                            .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(preset.frenchHelp)
                }

                Spacer(minLength: 4)

                HStack(spacing: 3) {
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 9))
                    Text("~\(appState.estimatedContextTokens) tok/tour")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.green.opacity(0.12), in: Capsule())
                .foregroundStyle(.green)
                .help("Empreinte estimée de la liste d'outils envoyée au modèle IA à chaque tour")
            }

            // Search box
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Filtrer les \(appState.tools.count) outils macOS...", text: $toolSearchText)
                    .textFieldStyle(.plain)
                    .font(.system(.caption))
                if !toolSearchText.isEmpty {
                    Button {
                        toolSearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            // Category filter pills with live enabled counts
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    categoryChip(
                        title: "Tous (\(appState.activeToolsCount))",
                        category: nil
                    )
                    ForEach(ToolCategory.allCases) { cat in
                        categoryChip(
                            title: "\(cat.frenchTitle) (\(appState.enabledCount(in: cat))/\(appState.totalCount(in: cat)))",
                            category: cat
                        )
                    }
                }
            }

            // Scrollable Tools list
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(filteredTools) { tool in
                        ToolToggleTile(
                            tool: tool,
                            isEnabled: appState.isToolEnabled(tool.name),
                            policy: appState.policy(for: tool),
                            isAlwaysAllowed: appState.isAlwaysAllowed(tool.name),
                            leaseMinutesRemaining: appState.remainingLeaseMinutes(for: tool.name),
                            estimatedTokens: appState.toolTokenCost(tool.name),
                            onToggle: { appState.setToolEnabled(tool.name, enabled: $0) },
                            onPolicyChange: { appState.setPolicy($0, for: tool.name) },
                            onRevokePermission: { appState.revokePermission(for: tool.name) }
                        )
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 260)
        }
    }

    private func categoryChip(title: String, category: ToolCategory?) -> some View {
        let isSelected = (selectedCategory == category)
        return Button {
            selectedCategory = category
        } label: {
            Text(title)
                .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05),
                    in: Capsule()
                )
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
    }
}
