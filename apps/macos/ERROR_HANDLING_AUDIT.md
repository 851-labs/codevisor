# Silent Error Handling Audit — macOS app

Audit date: 2026-07-11. Scope: `apps/macos/` excluding `Vendor/` (Ghostty) and tests.
Raw counts: ~141 `try?` sites, ~57 bare `catch {` blocks. Only one `os.Logger` exists in
non-vendor code (`ScratchpadModel`, subsystem `com.851labs.codevisor`, category `scratchpad`).

Legend: **(a)** must surface a human-readable error to the user · **(b)** log-only is fine
(best-effort/cosmetic) · **(c)** judgment call.

## Existing error surfaces (route new errors into these — don't invent new ones)

- `SessionModel.errorMessage` (`CodevisorCore/ViewModels/SessionModel.swift:52`) → session error banner (`Features/Session/SessionView.swift:383`, `SessionController.swift:234`)
- `status = .failed(serverErrorMessage(error))` pattern in `SessionController` / `SessionModel`
- Attachment `.failed(...)` + retry UI (`SessionController.swift:790-819`, `ComposerView.swift:608-624`)
- Settings `@State` error strings + `.alert` (`SettingsView.swift:59/226`, `AppearanceSettingsView.swift:12/81-91`, `MachinesSettingsView.swift:66-77`)
- `NSAlert` in menu commands (`MachineCommands.swift:79-83`, `AppUpdateCommands.swift:53-58`)
- `ServerStatusModel.errorMessage`, `MachineController.serverUpdatePhase.failed`, `LocalCodevisorServer.state = .unavailable`, `AppUpdateModel.phase = .failed`
- `CodevisorServerClientError` + `serverErrorMessage(_:)` helper (`Server/CodevisorServerClient.swift:4/15`)
- Missing entirely: any global/toast-style surface for errors that happen outside a session or a settings pane (persistence writes, background sync, event streams).

---

## Priority 1 — (a) silent failures of direct user actions

User clicks/taps something, it fails, and *nothing happens*:

| Site | What fails silently | User impact |
|---|---|---|
| `Codevisor/Features/Sidebar/SidebarView.swift:268` | `try? machines.addRemote(...)` | Add-remote-machine sheet submits, nothing added, no error |
| `Codevisor/Features/Settings/MachinesSettingsView.swift:39` | `try? machines.addRemote(...)` | Same, from Settings |
| `Codevisor/Features/Settings/MachinesSettingsView.swift:46` | `try? machines.renameMachine(...)` | Rename silently no-ops |
| `Codevisor/Features/Settings/MachinesSettingsView.swift:59` | `try? machines.removeMachine(...)` | Confirmed removal may not happen |
| `Codevisor/Features/Settings/AppearanceSettingsView.swift:55` | `try? manager.deleteCustomTheme(...)` | Trash click, theme not deleted, no feedback |
| `Codevisor/Features/Settings/SettingsView.swift:326` | harness toggle: `catch { revert toggle }` | Toggle snaps back with no reason shown |
| `Codevisor/Features/Session/AttachmentLightbox.swift:201-203` | `try?` fetch attachment bytes on Download | Download click does nothing |
| `Codevisor/Features/Session/AttachmentLightbox.swift:207` | `try? data.write(to:)` | User picked save location; file never written |
| `Codevisor/Features/Session/AttachmentViews.swift:188` | `try?` fetch bytes in `saveFile()` | Save click does nothing |
| `Codevisor/Features/Session/AttachmentViews.swift:192` | `try? data.write(to:)` | Silent save failure |
| `Codevisor/Features/Session/SessionController.swift:735/739` | `try?` read of dropped/picked attachment file | Unreadable file silently vanishes from composer (oversized files *do* surface) |
| `Codevisor/Features/Updates/AppUpdateInstaller.swift:103` | `try? helper.run()` then `NSApp.terminate` | Relaunch helper fails → app quits after update and never comes back |
| `Codevisor/Features/Onboarding/OnboardingView.swift:273` | `try? rescanHarnesses()` | "Rescan" button silently no-ops |
| `CodevisorCore/ViewModels/SessionModel.swift:399` | `try? transport.setMode(...)`, then optimistic UI update | Mode picker shows new mode; server never switched |
| `CodevisorCore/ViewModels/SessionModel.swift:577` | `try? setConfigOption(...)` on restore | UI shows model/effort selection agent didn't get |
| `CodevisorCore/ViewModels/ProjectListModel.swift:498-518` | `try?` on all server-side deletes | Deleted project/session reappears on next refresh |
| `Codevisor/Features/Terminal/GhosttyTerminalSurfaceAdapter.swift:145` | surface creation error only logged | Terminal pane opens blank/dead with no explanation |

## Priority 2 — (a) silent data loss / corruption paths

Persistence and sync failures that lose state invisibly:

| Site | What fails silently | Impact |
|---|---|---|
| `CodevisorCore/Persistence/PersistenceStore.swift:95` | `try? payload.write(...)` — **the choke point for ALL app-state writes** | Any settings/projects/sessions/panes/scratchpad write lost (full disk, permissions) |
| `CodevisorCore/Persistence/PersistenceStore.swift:39` | App Support dir unresolvable → silent fallback to **temp dir** | Data "saves" but is purged across launches |
| `CodevisorCore/Persistence/PersistenceStore.swift:47` | `try? createDirectory` | Every subsequent write fails silently |
| `CodevisorCore/Persistence/PersistenceStore.swift:75` | read error ≡ "no file" (both nil) | Can't distinguish corruption from fresh state |
| `CodevisorCore/Persistence/Repositories.swift:27` | corrupt projects/sessions file → `?? []` | Sidebar silently empty; next save **overwrites the corrupt file permanently** |
| `CodevisorCore/Persistence/Repositories.swift:31-32` | `try?` encode+save of full list | Whole list write lost |
| `CodevisorCore/Persistence/ScratchpadRepository.swift:47` | corrupt scratchpad → nil → treated as empty | User notes silently lost on next save |
| `CodevisorCore/Persistence/ScratchpadRepository.swift:51-52` | `try?` encode+save | Note save lost — and ScratchpadModel logs "save" *before* delegating, so the log claims success |
| `CodevisorCore/Persistence/PaneGroupRepository.swift:36-37/44` | `try?` save / corrupt load → `?? [:]` | Tab layouts lost; orphaned server PTYs |
| `CodevisorCore/Server/MachineController.swift:100` | corrupt registry decode → empty registry | All saved remote machines disappear |
| `CodevisorCore/Server/MachineController.swift:406-407` | `try?` encode+save registry | Machine registry write lost |
| `CodevisorCore/AppSettings.swift:65` | corrupt settings decode → defaults | All prefs reset, onboarding re-triggers, corrupt file then overwritten |
| `CodevisorCore/ViewModels/ProjectListModel.swift:379/381` | `compactMap { try? ... }` mapping server rows | A project/session that fails to map silently vanishes from sidebar |
| `CodevisorCore/ViewModels/ProjectListModel.swift:459` | `Task { try? upsertProject }` | Project never reaches server |
| `CodevisorCore/Server/ServerAgentService.swift:39` | `(try? allHarnesses()) ?? []` | "No agents available" indistinguishable from failed request |
| `CodevisorCore/Services/SessionImporter.swift:28` | per-harness listSessions failures ignored | Whole harness omitted from import picker |
| `Packages/CodevisorTheming/.../ThemeCatalog.swift:157-160` | corrupt bundled manifest → `[]` (assert is debug-only) | All preset themes vanish in release |
| `Packages/ACPKit/.../ToolCall.swift:153-165` | lenient decode: malformed `status`/`content` dropped | Completed tool call can appear to hang forever |
| `Packages/ACPKit/.../SessionConfig.swift:70-76` | options in neither shape → `[]` | Config picker renders with zero options — dead-end |

## Priority 3 — (c) judgment calls (surface, indicate, or at minimum log)

- `CodevisorCore/ViewModels/ProjectListModel.swift:391` — offline `catch {}`: stale list with **no offline indicator**
- `CodevisorCore/ViewModels/ProjectListModel.swift:473/488/491` — sync/bulk-sync failures silent
- `CodevisorCore/ViewModels/SessionModel.swift:486` — prompt queue fetch fail → shows empty
- `CodevisorCore/Server/ServerSessionTransport.swift:384/394/421/447/471/485` — lenient decoders drop attachments/goal/background-tasks/config on malformed payloads
- `CodevisorCore/Server/CodevisorServerClient.swift:982` — WS stream reconnects forever, no "disconnected" state
- `CodevisorCore/Server/MachineController.swift:248` — event-sync errors discarded
- `CodevisorCore/Server/CommandRunner.swift:63` — process output read failure → looks like empty output
- `CodevisorCore/Server/EnvironmentProbe.swift:145` — unreadable PATH dir skipped → installed CLI "not found"
- `CodevisorCore/Theme/ThemeManager.swift:86/96` — theme load failure → silent stock-Apple look
- `CodevisorCore/AppSettings.swift:129-130`, `ComposerDefaultsStore.swift:28/67-68`, `AppVariant.swift:47/53` — pref/cache writes lost
- `Codevisor/Features/Session/SessionController.swift:1349` — capability fetch `catch { return false }`
- `Codevisor/Features/Terminal/CodevisorGhosttyApp.swift:268` — terminal config write fails → silent default fonts/colors
- `Packages/CodevisorTheming/.../ThemeCatalog.swift:171-180` — unparseable imported theme silently omitted from picker
- `Packages/CodevisorTheming/.../ThemeCatalog.swift:146` — `try? removeItem` → orphaned file, UI says gone
- `Packages/CodeHighlighter/CodeHighlighter.swift:107-121` — missing/broken `highlighter.js` → ALL highlighting silently off for the session, never retried
- `Packages/CodeHighlighter/CodeHighlighter.swift:113` — JSContext has **no `exceptionHandler`**; JS errors invisible
- `Packages/ACPKit/.../ToolCall.swift:77` — malformed tool-call content element dropped from array
- `CodevisorCore/Services/AppUpdateModel.swift:157` — background update-check failure resets to `.idle` silently

## Priority 4 — (b) fine as-is, but should get a log line once logging exists

- Best-effort cleanup: `TerminalPane.swift:126` (DELETE server shell), `MachineController.swift:220/303`, `LocalCodevisorServer.swift:277` + shutdown/health `try?`s
- Cosmetic fallbacks: `BranchDiffBadge.swift:157/191`, `IconPickerView.swift:140-142`, `AttachmentViews.swift:37`, `MarkdownThemeAdapter.swift:30`, `InlineMarkdown.swift:15`, `ConfigOptionCache`, `SessionUpdate.swift:245` (phase)
- Deliberate resilience: `SessionModel.swift:184` (stream error → reconcile), `ServerSessionTransport.swift:208`, `SessionController.swift:1092` (log tail), `AppUpdateInstaller.swift:67` (rollback)
- Benign: all `try? await Task.sleep(...)` sites (cancellation-only)

---

## Remediation plan

### 1. Logging — unified logging (`os.Logger`), the macOS standard

- New file `CodevisorCore/Sources/CodevisorCore/Logging.swift`:

```swift
import os

public enum Log {
    public static let subsystem = "com.851labs.codevisor"  // matches ScratchpadModel's existing subsystem
    public static let persistence = Logger(subsystem: subsystem, category: "persistence")
    public static let server      = Logger(subsystem: subsystem, category: "server")
    public static let session     = Logger(subsystem: subsystem, category: "session")
    public static let machines    = Logger(subsystem: subsystem, category: "machines")
    public static let theming     = Logger(subsystem: subsystem, category: "theming")
    public static let terminal    = Logger(subsystem: subsystem, category: "terminal")
    public static let updates     = Logger(subsystem: subsystem, category: "updates")
    public static let acp         = Logger(subsystem: subsystem, category: "acp")
    public static let highlighting = Logger(subsystem: subsystem, category: "highlighting")
}
```

- Viewing: Console.app filtered on subsystem, or
  `log show --predicate 'subsystem == "com.851labs.codevisor"' --last 1h --info --debug`
  `log stream --predicate 'subsystem == "com.851labs.codevisor"' --level debug`
- Use `.error` for swallowed failures, `privacy: .public` on error descriptions so release builds aren't `<private>`.
- Optional "Export Logs" (Help menu) via `OSLogStore(scope: .currentProcessIdentifier)` → save to file for bug reports.
- Small packages (ACPKit/StreamMarkdown/CodeHighlighter/CodevisorTheming) that shouldn't depend on CodevisorCore: give each a private `Logger` with the same subsystem string.

### 2. Error surfacing

- Rule: never delete an existing surface — route into `SessionModel.errorMessage`, settings `.alert` states, `NSAlert` for menu commands.
- Add ONE new surface: a lightweight app-level transient error toast/banner (observable `ErrorReporter` in app environment) for errors with no natural home: persistence write failures, machine registry load corruption, sync/delete failures, WS persistent disconnect.
- Corruption loads (Repositories:27, ScratchpadRepository:47, AppSettings:65, MachineController:100): rename the corrupt file to `<name>.corrupt-<date>` instead of silently overwriting, log, and surface "Your X couldn't be read; a backup was kept at …".
- `serverErrorMessage(_:)` already exists as the human-readable formatter — extend rather than duplicate.

### 3. Suggested sequencing

1. `Log` enum + wire every (b)/(c) site with a one-line `.error`/`.warning` log — mechanical, zero behavior change.
2. Priority 1 table — route each into the nearest existing surface (mostly turning `try?` into `do/catch` + set error state).
3. `ErrorReporter` toast + Priority 2 persistence/corruption work (incl. `.corrupt` backup rename).
4. Priority 3 judgment calls, one product decision at a time.
