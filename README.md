# MacP — Native macOS MCP Bridge

**MacP** (v2.1) est une application macOS 100 % native (Swift 6 / SwiftUI, **zéro Electron**, **zéro Node.js/Python**) vivant dans la barre des menus et servant de pont **Model Context Protocol (MCP 2025-03-26)** entre macOS et vos clients IA (**Antigravity**, **Claude Desktop**, **Claude Code**, **Cursor**, **Windsurf**, etc.).

Elle expose **17 outils natifs macOS**, **6 ressources live (`macos://...`)** et **4 prompts prêts à l'emploi**, conçus pour être **rapides, silencieux (0 réveil CPU au repos)** et **économes en tokens LLM**, le tout protégé par une architecture **Zero-Trust Local First** avec consentement natif `NSAlert`, **Mode Bouclier** instantané et journal d'audit local rotatif.

---

## Points forts

* **Empreinte minimale, rapide & économe en énergie (100 % natif Apple)** :
  * **0 réveil CPU au repos** : serveur Unix Domain Socket et transports stdio 100 % événementiels (`kqueue` via `DispatchSourceRead`), sans boucle de polling ni threads bloqués.
  * **Contrôles système ultra-rapides** : volume audio et mode muet via **CoreAudio natif (< 1 ms, 0 sous-processus)** ; delta CPU Mach mis en cache (0 ms sur appels successifs) ; `EKEventStore` partagé pour Calendrier & Rappels ; recherche O(1) des rappels par identifiant ; arrêt anticipé des recherches Spotlight (`mdfind`).
  * **Télémétrie intelligente** : les jauges circulaires (CPU, RAM façon Moniteur d'activité, Batterie/Disque) ne tournent que lorsque le popover est ouvert sur l'onglet *Aperçu*.
  * **Rotation automatique des journaux** : lecture par la fin (`audit.jsonl`, 512 Ko max au démarrage) et rotation automatique (`audit.jsonl` 5 Mo, `macp.log` 2 Mo).
* **Économe en tokens LLM (coût & contexte)** :
  * **JSON compact** sur le fil MCP (`25–40 %` de tokens économisés sur chaque appel d'outil), automatiquement formaté pour la lecture humaine dans l'Inspecteur d'audit.
  * **Encodage JSON-RPC en une seule passe** (zéro double sérialisation pour les captures d'écran et gros payloads).
  * **Préréglages 1-clic (*Éco*, *Productivité*, *Complet*)** et compteur temps réel **`~tokens/tour`** dans le Dashboard pour piloter l'empreinte contexte des outils exposés.
* **Protocole MCP 2025-03-26 complet & concurrent** :
  * Négociation de version (`2024-11-05`, `2025-03-26`, `2025-06-18`).
  * **Exécution concurrente des requêtes** (un outil lent ne bloque jamais `ping`) et prise en charge réelle de **`notifications/cancelled`** (interruption immédiate des sous-processus avec escalade `SIGTERM` → `SIGKILL`).
  * **Tools** avec annotations (`readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`) et blocs **texte** + **image base64** (redimensionnement basse mémoire via ImageIO).
  * **Resources** live (`resources/list`, `resources/templates/list`, `resources/read`, notifications `list_changed`).
  * **Prompts** workflow (`prompts/list`, `prompts/get`).
* **Sécurité Zero-Trust Local First** :
  * **Isolation stricte** : socket Unix `0600` dans un dossier `0700`, vérification noyau de l'UID appelant (`getpeereid`), verrou atomique `O_EXLOCK`, et `FD_CLOEXEC` sur tous les sockets.
  * **Mode Bouclier (Pause globale)** : 1 clic pour bloquer instantanément toutes les requêtes IA.
  * **Consentement natif `NSAlert` sérialisé** (file FIFO anti-réentrance) avec aperçu scrollable monospace pour auditer intégralement les AppleScripts avant validation, **autorisation temporaire 15 min**, *Autoriser cette fois*, *Toujours autoriser* ou *Refuser*, et restauration automatique du focus applicatif.
  * **Inspecteur d'audit double panneau** : filtrage, taille & estimation tokens, formatage JSON lisible, export JSON / CSV.
* **Intégration macOS 1-clic** :
  * Détection et configuration 1-clic pour **Antigravity**, **Claude Desktop**, **Claude Code**, **Cursor** et **Windsurf** (préserve vos autres serveurs MCP et protège contre les JSON invalides).
  * **Lancer au démarrage** natif via `ServiceManagement` (`SMAppService.mainApp`).

---

## Architecture hybride à binaire unique

```text
Antigravity / Claude Desktop / Claude Code / Cursor / Windsurf
        │
        │  stdin / stdout (JSON-RPC 2.0 NDJSON)
        ▼
  MacP --stdio   (pont événementiel sans GUI, lancement auto -g de MacP.app si fermée)
        │
        │  Unix Domain Socket local (0600, getpeereid UID check, kqueue)
        │  ~/Library/Application Support/MacP/macp.sock
        ▼
    MacP.app     (MenuBarExtra SwiftUI + NSAlert + CoreAudio/EventKit/IOKit + AuditLogger)
```

* **Une seule icône Menu Bar** même lorsque plusieurs clients IA sont connectés simultanément.
* **Zéro pollution de `stdout`** : tous les logs techniques sont écrits dans `~/Library/Logs/MacP/macp.log`.
* **Fallback autonome (`--standalone`)** : exécute le serveur MCP directement en processus sur `stdin`/`stdout` (tests CLI / headless).

---

## Les 17 outils MCP natifs

### Productivité Apple (11 outils)

| Outil | Description | Paramètres principaux | Politique par défaut |
| :--- | :--- | :--- | :--- |
| `macos_list_shortcuts` | Liste les Raccourcis macOS (`/usr/bin/shortcuts list`) | `folder` *(opt.)* | Automatique |
| `macos_run_shortcut` | Exécute un Raccourci macOS sans shell | `shortcut_name`, `input_text` *(opt.)* | Demander 1x |
| `macos_read_clipboard` | Lit le texte du presse-papiers (`NSPasteboard.general`) | `max_length` *(défaut 16 000)* | Demander 1x |
| `macos_write_clipboard` | Remplace le contenu du presse-papiers | `text` | Demander 1x |
| `macos_list_calendar_events` | Liste les événements du Calendrier (`EventKit`) | `date` *(YYYY-MM-DD)*, `days` *(1–31)*, `calendar_name` | Demander 1x |
| `macos_create_calendar_event` | Crée un événement dans le Calendrier (`EventKit`) | `title`, `start_iso`, `end_iso`, `calendar_name`, `location`, `notes`, `is_all_day` | Demander 1x |
| `macos_list_reminders` | Liste les Rappels macOS (`EventKit`) | `list_name`, `include_completed`, `limit` | Demander 1x |
| `macos_create_reminder` | Crée un Rappel (`EventKit`) | `title`, `list_name`, `due_iso`, `notes`, `priority` *(0–9)* | Demander 1x |
| `macos_complete_reminder` | Termine un Rappel (lookup O(1) par ID ou par titre) | `reminder_id` ou `title` | Demander 1x |
| `macos_spotlight_search` | Recherche Spotlight (`mdfind`) avec arrêt anticipé | `query`, `directory`, `name_only`, `limit` | Demander 1x |
| `macos_send_notification` | Affiche une bannière de notification macOS native | `title`, `message`, `subtitle`, `sound` | Demander 1x |

### Workspace & Système (4 outils)

| Outil | Description | Paramètres principaux | Politique par défaut |
| :--- | :--- | :--- | :--- |
| `macos_system_stats` | CPU % + loadavg (Mach, delta caché), RAM (Moniteur d'activité), Batterie (`IOKit.ps`), Disque, Apparence live, Thermique & Uptime | *(aucun)* | Automatique |
| `macos_list_running_apps` | Liste les applications ouvertes et l'app active (`NSWorkspace`) | `include_background`, `include_paths` *(opt.)* | Automatique |
| `macos_open_app_or_url` | Ouvre/active une app, un fichier/dossier ou une URL sécurisée | `app_name` ou `url` ou `file_path` | Demander 1x |
| `macos_system_controls` | Volume audio (0–100) et muet via **CoreAudio (< 1 ms)** + Dark Mode | `action` (`get_state`, `set_volume`, `set_mute`, `set_dark_mode`), `volume`, `muted`, `dark_mode` | Demander 1x |

### Vision (1 outil)

| Outil | Description | Paramètres principaux | Politique par défaut |
| :--- | :--- | :--- | :--- |
| `macos_capture_screen` | Capture silencieusement l'écran ou la vraie fenêtre active (ignore MacP), redimensionne via ImageIO et renvoie un **bloc `image` MCP (base64)** | `target` (`main_display`, `frontmost_window`), `max_width` *(400–2560)*, `format` (`jpeg`, `png`), `quality` *(40–95)* | **Toujours demander** |

### Automatisation Pro (1 outil)

| Outil | Description | Paramètres principaux | Politique par défaut |
| :--- | :--- | :--- | :--- |
| `macos_run_applescript` | Exécute un script **AppleScript** ou **JXA** via `/usr/bin/osascript` (Safari, Finder, Notes, Mail, Music…) avec aperçu intégral avant accord | `script`, `language` (`AppleScript`, `JavaScript`), `timeout_seconds` *(1–60)* | **Toujours demander** |

---

## Ressources MCP live (`resources/list` & `resources/read`)

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
MacP --status               # Vérifie si le démon MacP.app écoute sur le socket Unix (code retour 0/1)
MacP --version              # Affiche la version (MacP 2.1.0)
MacP --help                 # Affiche l'aide CLI
```

---

## Configuration des clients IA

### Méthode recommandée (1 clic)
Ouvrez **MacP** dans la barre des menus → onglet **Clients** → cliquez sur **Installer** pour **Antigravity**, **Claude Desktop**, **Claude Code**, **Cursor** ou **Windsurf**.

### Méthode manuelle (JSON)

* **Antigravity** : `~/.gemini/config/mcp_config.json`
* **Claude Desktop** : `~/Library/Application Support/Claude/claude_desktop_config.json`
* **Claude Code** : `~/.claude.json`
* **Cursor** : `~/.cursor/mcp.json`
* **Windsurf** : `~/.codeium/windsurf/mcp_config.json`

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

---

## Structure du dépôt

```text
MacP/
├── MacP.xcodeproj/              # Projet Xcode macOS (cible MacP + package local MacPCore)
├── Packages/MacPCore/           # Moteur MCP Swift 6 testable indépendamment
│   ├── Sources/MacPCore/
│   │   ├── Utilities/           # MacPVersion, ISO8601Codec (zero-alloc), TokenEstimator
│   │   ├── Protocol/            # JSONValue, JSON-RPC 2.0 (single-pass), MCPTypes
│   │   ├── Transport/           # StdioTransport (kqueue), UnixSocketTransport (0600 + getpeereid + O_EXLOCK)
│   │   ├── Security/            # ToolSettingsStore (+ presets Éco), PermissionManager (FIFO), AuditLogger (rotation)
│   │   ├── Tools/               # 17 outils natifs + NativeProcessRunner + EventKitStore + CoreAudioVolume
│   │   └── Server/              # MCPServerSession (concurrent + cancellation), MCPProviders, MacPBridgeService
│   └── Tests/MacPCoreTests/     # 23 tests unitaires & d'intégration (Swift Testing)
├── MacPApp/                     # Application SwiftUI MenuBarExtra
│   ├── Entry/                   # MacPMain (@main hybride GUI / --stdio / --status)
│   ├── App/                     # MacPMenuBarApp, AppState (@Observable)
│   ├── Security/                # NativePermissionPrompter (NSAlert + aperçu script + restauration focus)
│   ├── Services/                # MCPClientConfigManager (5 clients 1-clic), LaunchAtLoginManager (SMAppService)
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
# 1. Exécuter la suite de tests MacPCore (23 tests Swift Testing)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path Packages/MacPCore

# 2. Compiler MacP.app en Release (binaire universel arm64 + x86_64)
./Scripts/build-app.sh Release

# 3. Installer dans /Applications
rm -rf /Applications/MacP.app
mv .build/xcode/Build/Products/Release/MacP.app /Applications/MacP.app
```

---

## Journaux & Diagnostic

* **Journal d'audit IA** : `~/Library/Logs/MacP/audit.jsonl` (rotation auto à 5 Mo, consultable & exportable en JSON/CSV)
* **Logs techniques** : `~/Library/Logs/MacP/macp.log` (rotation auto à 2 Mo)
* **Socket IPC local** : `~/Library/Application Support/MacP/macp.sock`
