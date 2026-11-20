# Cahier des Charges Technique : MacP (Native macOS MCP Bridge)

## 1. Vision du Projet
**Nom de code :** MacP
**Objectif :** Développer une application macOS native, légère et sécurisée (vivant dans la barre des menus), servant de pont (Server) entre le système d'exploitation macOS et des clients LLM locaux ou cloud via le **Model Context Protocol (MCP)**.
**Philosophie :** Zéro Electron. Empreinte mémoire minimale. Respect strict des Apple Human Interface Guidelines (HIG) avec une esthétique "Liquid Glass" et "Bento Grid". Sécurité "Local First" avec un système de permission granulaire pour l'IA.

---

## 2. Contexte Technique pour l'Agent IA
**À l'attention de l'Agent de Développement :** 
Ce projet nécessite une excellente maîtrise de l'écosystème Apple natif. Ne proposez aucune dépendance Node.js, Python ou Electron. Tout doit être géré en Swift natif. Une attention particulière doit être portée à la gestion asynchrone des flux (I/O) standards, car le protocole MCP communique principalement via `stdin` et `stdout` lorsqu'il est exécuté en tant que sous-processus par des clients comme Cursor ou Claude Desktop.

### Stack Technique
*   **Langage :** Swift 6 / Swift 5.10
*   **UI :** SwiftUI (cible macOS 14.0 minimum)
*   **Lifecycle :** App `MenuBarExtra` (sans fenêtre principale par défaut)
*   **Communication :** `Foundation` (FileHandle pour stdio, `Codable` pour le parsing JSON-RPC 2.0)
*   **Intégrations Système :** `AppKit`, `NSWorkspace`, `EventKit` (Calendrier/Rappels), `Process` (pour exécuter des AppleScripts/Shortcuts)

---

## 3. Architecture du Protocole (MCP)
Le Model Context Protocol utilise JSON-RPC 2.0. CoreContext doit implémenter un serveur MCP capable de gérer le cycle de vie suivant :
1.  **Initialization :** Réception de `initialize`, réponse avec les capacités (Capabilities) du serveur, puis réception de `notifications/initialized`.
2.  **Tool Discovery :** Réception de `tools/list`, réponse avec la liste des outils macOS disponibles (ex: `run_shortcut`, `read_calendar`, `get_system_stats`).
3.  **Tool Execution :** Réception de `tools/call`, exécution de l'action native macOS, et renvoi du résultat formaté en texte/JSON.

---

## 4. Fonctionnalités Principales (MVP)

### 4.1. Le Moteur (Backend natif)
*   **Boucle d'écoute Stdio :** Un service s'exécutant en arrière-plan pour écouter continuellement `FileHandle.standardInput` sans bloquer le thread principal.
*   **Parseur JSON-RPC :** Décodage robuste des requêtes entrantes et routage vers les "Tools" correspondants.
*   **Écriture Stdio :** Envoi des réponses via `FileHandle.standardOutput` avec un formatage JSON strict.

### 4.2. Les Outils (MCP Tools) à exposer à l'IA
1.  **`macos_run_shortcut`** :
    *   *Description :* Permet à l'IA d'exécuter un Raccourci macOS existant.
    *   *Arguments :* `shortcut_name` (String).
    *   *Implémentation :* Utiliser `Process` pour appeler la commande CLI `shortcuts run "nom"`.
2.  **`macos_read_clipboard`** :
    *   *Description :* Lit le contenu textuel actuel du presse-papiers.
    *   *Implémentation :* Utiliser `NSPasteboard.general`.
3.  **`macos_system_stats`** :
    *   *Description :* Récupère l'état de la batterie et l'utilisation CPU/RAM (basique).
4.  **`macos_list_calendar_events`** *(Phase 2)* :
    *   *Description :* Liste les événements du jour.
    *   *Implémentation :* `EventKit` (`EKEventStore`).

### 4.3. Interface Utilisateur (SwiftUI)
*   **Menu Bar App :** L'application n'apparaît que dans la barre des menus en haut à droite.
*   **Popover "Dashboard" :** Au clic sur l'icône, un Popover s'ouvre.
    *   *Design :* Utilisation de `.background(.regularMaterial)` pour l'effet translucide Liquid Glass.
    *   *Layout :* Grille Bento (`LazyVGrid`).
    *   *Composants :*
        *   Indicateur de statut (Pastille verte si connecté à un client, rouge sinon).
        *   Toggles pour activer/désactiver chaque outil individuellement (ex: interdire l'accès au calendrier).
        *   Un log visuel minimaliste des 5 dernières requêtes traitées.

### 4.4. Sécurité & Permissions (Critique)
L'IA ne doit pas exécuter d'actions sensibles sans consentement.
*   **Sandboxing :** Configurer les entitlements correctement (`App Sandbox`, `Resource Access`).
*   **User Prompt :** Si un outil critique (ex: modification de fichiers, accès Contacts/Calendrier) est appelé pour la première fois, afficher une alerte macOS native (NSAlert) demandant l'autorisation à l'utilisateur.
*   **Audit Log :** Enregistrer toutes les actions de l'IA dans un fichier de log local consultable depuis le Dashboard.

---

## 5. Design Guidelines (Apple HIG)
*   **Typographie :** Utiliser exclusivement le système de polices Apple (`.font(.system(...))`), avec une gestion du poids hiérarchisée (ex: `.headline`, `.subheadline`).
*   **Couleurs :** Supporter le Dark Mode nativement. Utiliser les couleurs sémantiques (ex: `Color.secondary`, `Color.accentColor`).
*   **Espaces et Alignements :** Maintenir des marges cohérentes (Padding de 16pt ou 20pt entre les cartes du Bento Grid). Coins arrondis (Corner Radius continu type Apple) pour les éléments de la grille.

---

## 6. Roadmap d'implémentation (Step-by-Step pour l'Agent)

**Phase 1 : Setup & Base Mécanique (I/O)**
1.  Créer le projet Xcode macOS en Swift/SwiftUI. Configurer la cible `MenuBarExtra`.
2.  Implémenter un `StdioTransport` : lire les lignes de `stdin` de manière asynchrone (Task / FileHandle) et écrire sur `stdout`. *Attention : Xcode console interfère avec stdio, prévoir des logs dans un fichier sur le disque pour le debug.*

**Phase 2 : Protocole JSON-RPC & MCP**
1.  Créer les modèles de données `Codable` pour les requêtes MCP (`initialize`, `tools/list`, `tools/call`).
2.  Mettre en place le routeur interne pour traiter la poignée de main (`initialize`) et renvoyer la réponse correcte.

**Phase 3 : Implémentation des Tools**
1.  Créer le protocole `MCPTool` (Nom, Description, Schema des arguments, Fonction d'exécution).
2.  Implémenter `ShortcutTool` et `ClipboardTool`.
3.  Connecter la réception de la requête `tools/call` à l'exécution de ces outils.

**Phase 4 : Interface Utilisateur & Permissions**
1.  Construire le Bento Grid Dashboard dans SwiftUI.
2.  Connecter les Toggles de l'UI à un `UserDefaults` pour activer/désactiver les outils dynamiquement.
3.  Ajouter l'alerte d'autorisation (NSAlert) pour les actions sensibles.

**Phase 5 : Packaging & Test**
1.  Compiler le binaire.
2.  Créer la configuration JSON côté client (ex: dans `claude_desktop_config.json` ou Cursor) pointant vers l'exécutable compilé avec l'argument approprié.
3.  Valider la communication de bout en bout.