# MacP — Native macOS MCP Bridge

**MacP** (v2.0) est une application macOS 100 % native (Swift 6 / SwiftUI, **zéro Electron**, **zéro Node.js/Python**) vivant dans la barre des menus et servant de pont **Model Context Protocol (MCP 2025-03-26)** entre macOS et vos clients IA (**Antigravity**, **Claude Desktop**, **Cursor**, etc.).

Elle expose **17 outils natifs macOS**, **6 ressources live (`macos://...`)** et **4 prompts prêts à l'emploi**, le tout protégé par une architecture **Zero-Trust Local First** avec consentement natif `NSAlert`, **Mode Bouclier** instantané et journal d'audit local.

---

## Points forts

* **Empreinte minimale & 100 % natif Apple** : binaire universel (`arm64` + `x86_64`) d'environ **6 Mo**, ciblant macOS 14.0+ (Sonoma, Sequoia et macOS 26/27).
* **Esthétique Liquid Glass & Bento Grid (Apple HIG)** :
  * Utilise `.glassEffect(.regular, in: ...)` natif sur macOS 26/27 avec fallback translucide `.regularMaterial` + bordure spéculaire sur macOS 14–15.
  * Icône d'application macOS Squircle Liquid Glass générée nativement en CoreGraphics dans tous les formats Retina (`16x16` à `512x512@2x`).
  * Dashboard Menu Bar en **3 onglets** (*Aperçu*, *Outils*, *Clients*) avec **jauges circulaires live** (CPU, RAM, Batterie / Stockage) actives uniquement lorsque le popover est ouvert.
* **Protocole MCP 2025-03-26 complet** :
  * Négociation de version (`2024-11-05`, `2025-03-26`, `2025-06-18`).
  * **Tools** avec annotations officielles (`readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`) et blocs de contenu **texte** et **image base64**.
  * **Resources** live (`resources/list`, `resources/read`, notifications `list_changed`).
  * **Prompts** workflow (`prompts/list`, `prompts/get`).
* **Sécurité Zero-Trust Local First** :
  * **Mode Bouclier (Pause globale)** : 1 clic dans l'en-tête pour bloquer instantanément toutes les requêtes IA (l'icône de barre des menus passe en bouclier barré).
  * **Politique granulaire par outil** : *Automatique*, *Demander 1x*, ou *Toujours demander* (obligatoire par défaut pour la capture d'écran et AppleScript/JXA).
  * **Consentement natif `NSAlert`** avec **autorisation temporaire de 15 minutes** (compte à rebours en direct + révocation 1-clic), *Autoriser cette fois*, *Toujours autoriser* ou *Refuser*.
  * **Inspecteur d'audit JSON double panneau** : historique persisté dans `~/Library/Logs/MacP/audit.jsonl`, filtrable par résultat/client/outil, inspecteur des arguments/résultats JSON et **export JSON / CSV**.
* **Intégration macOS complète** :
  * **Configuration 1-clic** avec détection automatique pour **Antigravity**, **Claude Desktop** et **Cursor** (préserve vos autres serveurs MCP existants).
  * **Lancer au démarrage** natif via `ServiceManagement` (`SMAppService.mainApp`).

---

## Architecture hybride à binaire unique

```text
Antigravity / Claude Desktop / Cursor
        │
        │  stdin / stdout (JSON-RPC 2.0 NDJSON)
        ▼
  MacP --stdio   (pont léger sans GUI, lancement auto -g de MacP.app si fermée)
        │
        │  Unix Domain Socket local (0600, utilisateur courant uniquement)
        │  ~/Library/Application Support/MacP/macp.sock
        ▼
    MacP.app     (MenuBarExtra SwiftUI + NSAlert + EventKit/IOKit + AuditLogger)
```

* **Une seule icône Menu Bar** même lorsque plusieurs clients IA (ex. Antigravity + Cursor + Claude Desktop) sont connectés simultanément.
* **Zéro pollution de `stdout`** : tous les logs techniques sont écrits dans `~/Library/Logs/MacP/macp.log`.
* **Fallback autonome (`--standalone`)** : permet d'exécuter le serveur MCP directement en processus sur `stdin`/`stdout` (utile pour tests CLI ou environnements headless).

---

## Les 17 outils MCP natifs

### Productivité Apple (11 outils)

| Outil | Description | Paramètres principaux | Politique par défaut |
| :--- | :--- | :--- | :--- |
| `macos_list_shortcuts` | Liste les Raccourcis macOS installés (`/usr/bin/shortcuts list`) | `folder` *(opt.)* | Automatique |
| `macos_run_shortcut` | Exécute un Raccourci macOS sans shell (`/usr/bin/shortcuts run`) | `shortcut_name`, `input_text` *(opt.)* | Demander 1x |
| `macos_read_clipboard` | Lit le texte actuel du presse-papiers (`NSPasteboard.general`) | `max_length` *(opt.)* | Demander 1x |
| `macos_write_clipboard` | Remplace le contenu du presse-papiers (`NSPasteboard.general`) | `text` | Demander 1x |
| `macos_list_calendar_events` | Liste les événements du Calendrier (`EventKit`) | `date` *(YYYY-MM-DD)*, `days` *(1–31)*, `calendar_name` | Demander 1x |
| `macos_create_calendar_event` | Crée un nouvel événement dans le Calendrier (`EventKit`) | `title`, `start_iso`, `end_iso`, `calendar_name`, `location`, `notes`, `is_all_day` | Demander 1x |
| `macos_list_reminders` | Liste les Rappels macOS (`EventKit`) | `list_name`, `include_completed`, `limit` | Demander 1x |
| `macos_create_reminder` | Crée un nouveau Rappel (`EventKit`) | `title`, `list_name`, `due_iso`, `notes`, `priority` | Demander 1x |
| `macos_complete_reminder` | Marque un Rappel incomplet comme terminé (`EventKit`) | `reminder_id` ou `title` | Demander 1x |
| `macos_spotlight_search` | Recherche Spotlight native (`/usr/bin/mdfind`) avec métadonnées | `query`, `directory`, `name_only`, `limit` | Demander 1x |
| `macos_send_notification` | Affiche une bannière de notification macOS native | `title`, `message`, `subtitle`, `sound` | Demander 1x |

### Workspace & Système (4 outils)

| Outil | Description | Paramètres principaux | Politique par défaut |
| :--- | :--- | :--- | :--- |
| `macos_system_stats` | CPU % + loadavg (Mach), RAM (`vm_statistics64`), Batterie (`IOKit.ps`), Disque, Apparence, Thermique & Uptime | *(aucun)* | Automatique |
| `macos_list_running_apps` | Liste les applications ouvertes et l'application au premier plan (`NSWorkspace`) | `include_background` *(opt.)* | Automatique |
| `macos_open_app_or_url` | Ouvre/active une app, un fichier/dossier ou une URL sécurisée (`NSWorkspace`) | `app_name` ou `url` ou `file_path` | Demander 1x |
| `macos_system_controls` | Lit ou modifie le volume audio (0–100), le mode muet et le Dark Mode | `action` (`get_state`, `set_volume`, `set_mute`, `set_dark_mode`), `volume`, `muted`, `dark_mode` | Demander 1x |

### Vision (1 outil)

| Outil | Description | Paramètres principaux | Politique par défaut |
| :--- | :--- | :--- | :--- |
| `macos_capture_screen` | Capture silencieusement l'écran principal ou la fenêtre active, redimensionne et renvoie un **bloc `image` MCP (base64)** + métadonnées | `target` (`main_display`, `frontmost_window`), `max_width` *(400–2560)*, `format` (`jpeg`, `png`) | **Toujours demander** |

### Automatisation Pro (1 outil)

| Outil | Description | Paramètres principaux | Politique par défaut |
| :--- | :--- | :--- | :--- |
| `macos_run_applescript` | Exécute un script **AppleScript** ou **JavaScript for Automation (JXA)** via `/usr/bin/osascript` (Safari, Finder, Notes, Mail, Music…) | `script`, `language` (`AppleScript`, `JavaScript`), `timeout_seconds` *(1–60)* | **Toujours demander** |

---

## Ressources MCP live (`resources/list` & `resources/read`)

Toutes les ressources respectent le Mode Bouclier, les toggles d'outils et les politiques de permission :

| URI | Description |
| :--- | :--- |
| `macos://system/stats` | Télémétrie matérielle live (CPU, RAM, batterie, disque, thermique) |
| `macos://apps/running` | Applications ouvertes & app active |
| `macos://shortcuts/list` | Liste des Raccourcis macOS installés |
| `macos://clipboard/current` | Contenu texte actuel du presse-papiers |
| `macos://calendar/today` | Événements du Calendrier pour aujourd'hui |
| `macos://reminders/open` | Rappels non terminés |

## Prompts MCP intégrés (`prompts/list` & `prompts/get`)

| Prompt | Arguments | Workflow |
| :--- | :--- | :--- |
| `daily_briefing` | `days` *(opt.)* | Combine Calendrier, Rappels et santé du Mac en un briefing synthétique |
| `focus_mode_setup` | `goal` *(requis)* | Prépare le Mac pour une session Focus (apps, raccourci, audio/Dark Mode, notification) |
| `clipboard_assistant` | `task` *(opt.)* | Lit le presse-papiers, transforme le texte et propose de le recopier |
| `screen_troubleshooter` | `question` *(opt.)* | Capture la fenêtre active et analyse visuellement ce qui est affiché |

---

## Options CLI (`MacP`)

```bash
MacP                        # Lance l'application Menu Bar et le serveur Unix Socket local
MacP --stdio                # Mode pont MCP stdio (se connecte à MacP.app, la lance en arrière-plan si besoin)
MacP --stdio --standalone   # Exécute le serveur MCP directement en processus sans passer par le socket
MacP --stdio --socket PATH  # Utilise un chemin de socket Unix personnalisé
MacP --version              # Affiche la version (MacP 2.0.0)
MacP --help                 # Affiche l'aide CLI
```

---

## Configuration des clients IA

### Méthode recommandée (1 clic)
Ouvrez **MacP** dans la barre des menus → onglet **Clients** → cliquez sur **Installer** pour **Antigravity**, **Claude Desktop** ou **Cursor**.

### Méthode manuelle (JSON)

* **Antigravity** : `~/.gemini/config/mcp_config.json`
* **Claude Desktop** : `~/Library/Application Support/Claude/claude_desktop_config.json`
* **Cursor** : `~/.cursor/mcp.json`

```json
{
  "mcpServers": {
    "macp": {
      "command": "/Applications/MacP.app/Contents/MacOS/MacP",
      "args": ["--stdio"]
    }
  }
}
```

Des exemples prêts à l'emploi sont également disponibles dans `Config/claude_desktop_config.example.json` et `Config/cursor_mcp.example.json`.

---

## Permissions macOS (TCC)

MacP est distribué localement avec **Hardened Runtime** (sans App Sandbox strict, requis pour `/usr/bin/shortcuts`). Lors de la première utilisation des outils concernés, macOS peut vous demander d'accorder :

* **Calendriers** : pour `macos_list_calendar_events` et `macos_create_calendar_event`
* **Rappels** : pour `macos_list_reminders`, `macos_create_reminder` et `macos_complete_reminder`
* **Enregistrement de l'écran** : pour `macos_capture_screen`
* **Automatisation (System Events / apps cibles)** : pour `macos_system_controls` (Dark Mode) et `macos_run_applescript`

---

## Structure du dépôt

```text
MacP/
├── MacP.xcodeproj/              # Projet Xcode macOS (cible MacP + package local MacPCore)
├── Packages/MacPCore/           # Moteur MCP Swift 6 testable indépendamment
│   ├── Sources/MacPCore/
│   │   ├── Protocol/            # JSONValue, JSON-RPC 2.0, MCPTypes (Tools/Resources/Prompts)
│   │   ├── Transport/           # StdioTransport (NDJSON), UnixSocketTransport (0600)
│   │   ├── Security/            # ToolSettingsStore, PermissionManager (leases 15m), AuditLogger
│   │   ├── Tools/               # Les 17 outils natifs macOS
│   │   └── Server/              # MCPServerSession, MCPResourceCatalog, MCPPromptCatalog, MacPBridgeService
│   └── Tests/MacPCoreTests/     # 17 tests unitaires & d'intégration (Swift Testing)
├── MacPApp/                     # Application SwiftUI MenuBarExtra
│   ├── Entry/                   # MacPMain (@main hybride GUI / --stdio)
│   ├── App/                     # MacPMenuBarApp, AppState (@Observable)
│   ├── Security/                # NativePermissionPrompter (NSAlert)
│   ├── Services/                # MCPClientConfigManager (1-clic), LaunchAtLoginManager (SMAppService)
│   ├── Views/                   # DashboardView + BentoCard (Liquid Glass), TelemetryBentoGrid, AuditLogSheetView
│   ├── Resources/               # Info.plist (LSUIElement + TCC), MacP.entitlements
│   └── Assets.xcassets/         # AppIcon Squircle Liquid Glass + AccentColor
├── Config/                      # Exemples JSON pour Claude Desktop & Cursor
└── Scripts/
    ├── build-app.sh             # Build Release/Debug via xcodebuild
    └── generate-app-icon.swift  # Générateur CoreGraphics des 10 tailles d'icône macOS
```

---

## Compilation, tests & installation

```bash
# 1. Exécuter la suite de tests MacPCore (17 tests Swift Testing)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path Packages/MacPCore

# 2. (Optionnel) Régénérer les 10 tailles d'icône Squircle Liquid Glass
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift Scripts/generate-app-icon.swift

# 3. Compiler MacP.app en Release (binaire universel arm64 + x86_64)
./Scripts/build-app.sh Release

# 4. Installer dans /Applications
rm -rf /Applications/MacP.app
mv .build/xcode/Build/Products/Release/MacP.app /Applications/MacP.app
```

---

## Journaux & Diagnostic

* **Journal d'audit IA** : `~/Library/Logs/MacP/audit.jsonl` (consultable, filtrable et exportable en JSON/CSV depuis l'app)
* **Logs techniques** : `~/Library/Logs/MacP/macp.log`
* **Socket IPC local** : `~/Library/Application Support/MacP/macp.sock`
