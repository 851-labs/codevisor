import AppKit
import Foundation
import GhosttyKit
import CodevisorCore
import CodevisorTheming
import SwiftUI
import os

// MARK: - Action dispatch

extension CodevisorGhosttyApp {

    /// Runs a libghostty action. NOT main-isolated: while most actions arrive
    /// on the main thread (the app loop ticks there), the renderer thread
    /// fires cell-size and progress-report actions during a live resize —
    /// upstream Ghostty deliberately leaves this handler unisolated and hops
    /// those to main. Each case therefore extracts its C payload
    /// synchronously (the pointers die with the callback) and applies UI
    /// state via `onMain`; the Bool (action supported?) is decided
    /// synchronously from the tag and payload validity.
    nonisolated static func action(_ app: ghostty_app_t, target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        switch target.tag {
        case GHOSTTY_TARGET_APP, GHOSTTY_TARGET_SURFACE:
            break
        default:
            Ghostty.logger.warning("unknown action target=\(target.tag.rawValue, privacy: .public)")
            return false
        }

        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            guard let surfaceView = surfaceView(for: target) else { return false }
            guard let title = String(cString: action.action.set_title.title!, encoding: .utf8) else { return false }
            onMain { surfaceView.setTitle(title) }

        case GHOSTTY_ACTION_PWD:
            guard let surfaceView = surfaceView(for: target) else { return false }
            guard let pwd = String(cString: action.action.pwd.pwd!, encoding: .utf8) else { return false }
            onMain { surfaceView.pwd = pwd }

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            guard let surfaceView = surfaceView(for: target) else { return false }
            let shape = action.action.mouse_shape
            onMain { surfaceView.setCursorShape(shape) }

        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            guard let surfaceView = surfaceView(for: target) else { return false }
            let visible: Bool
            switch action.action.mouse_visibility {
            case GHOSTTY_MOUSE_VISIBLE: visible = true
            case GHOSTTY_MOUSE_HIDDEN: visible = false
            default: return false
            }
            onMain { surfaceView.setCursorVisibility(visible) }

        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            guard let surfaceView = surfaceView(for: target) else { return false }
            let v = action.action.mouse_over_link
            let url: String?
            if v.len > 0 {
                url = String(data: Data(bytes: v.url!, count: v.len), encoding: .utf8)
            } else {
                url = nil
            }
            onMain { surfaceView.hoverUrl = url }

        case GHOSTTY_ACTION_INITIAL_SIZE:
            guard let surfaceView = surfaceView(for: target) else { return false }
            let v = action.action.initial_size
            let size = NSSize(width: Double(v.width), height: Double(v.height))
            onMain { surfaceView.initialSize = size }

        case GHOSTTY_ACTION_CELL_SIZE:
            guard let surfaceView = surfaceView(for: target) else { return false }
            let v = action.action.cell_size
            let backingSize = NSSize(width: Double(v.width), height: Double(v.height))
            onMain { [weak surfaceView] in
                guard let surfaceView else { return }
                surfaceView.cellSize = surfaceView.convertFromBacking(backingSize)
            }

        case GHOSTTY_ACTION_RENDERER_HEALTH:
            guard let surfaceView = surfaceView(for: target) else { return false }
            let health = action.action.renderer_health
            onMain {
                NotificationCenter.default.post(
                    name: Ghostty.Notification.didUpdateRendererHealth,
                    object: surfaceView,
                    userInfo: ["health": health]
                )
            }

        case GHOSTTY_ACTION_KEY_SEQUENCE:
            guard let surfaceView = surfaceView(for: target) else { return false }
            let v = action.action.key_sequence
            if v.active {
                let shortcut = Ghostty.keyboardShortcut(for: v.trigger)
                onMain {
                    NotificationCenter.default.post(
                        name: Ghostty.Notification.didContinueKeySequence,
                        object: surfaceView,
                        userInfo: [Ghostty.Notification.KeySequenceKey: shortcut as Any]
                    )
                }
            } else {
                onMain {
                    NotificationCenter.default.post(
                        name: Ghostty.Notification.didEndKeySequence,
                        object: surfaceView
                    )
                }
            }

        case GHOSTTY_ACTION_KEY_TABLE:
            guard let surfaceView = surfaceView(for: target) else { return false }
            guard let keyTable = Ghostty.Action.KeyTable(c: action.action.key_table) else { return false }
            onMain {
                NotificationCenter.default.post(
                    name: Ghostty.Notification.didChangeKeyTable,
                    object: surfaceView,
                    userInfo: [Ghostty.Notification.KeyTableKey: keyTable]
                )
            }

        case GHOSTTY_ACTION_CONFIG_CHANGE:
            // Clone the config so we own the memory (upstream L2194-2240) —
            // synchronously: the source pointer dies with the callback.
            let config = Ghostty.Config(clone: action.action.config_change.config)
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                let host = hostApp(from: ghostty_app_userdata(app))
                onMain {
                    NotificationCenter.default.post(
                        name: .ghosttyConfigDidChange,
                        object: nil,
                        userInfo: [SwiftUI.Notification.Name.GhosttyConfigChangeKey: config]
                    )
                    host.config = config
                }
            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface,
                    let surfaceView = surfaceView(from: surface)
                else { return false }
                onMain {
                    NotificationCenter.default.post(
                        name: .ghosttyConfigDidChange,
                        object: surfaceView,
                        userInfo: [SwiftUI.Notification.Name.GhosttyConfigChangeKey: config]
                    )
                }
            default:
                return false
            }

        case GHOSTTY_ACTION_RELOAD_CONFIG:
            // Rebuild our themed config (Codevisor has no on-disk user config flow).
            let host = hostApp(from: ghostty_app_userdata(app))
            onMain { host.reloadConfig() }

        case GHOSTTY_ACTION_COLOR_CHANGE:
            guard let surfaceView = surfaceView(for: target) else { return false }
            let change = Ghostty.Action.ColorChange(c: action.action.color_change)
            onMain {
                NotificationCenter.default.post(
                    name: .ghosttyColorDidChange,
                    object: surfaceView,
                    userInfo: [SwiftUI.Notification.Name.GhosttyColorChangeKey: change]
                )
            }

        case GHOSTTY_ACTION_RING_BELL:
            guard let surfaceView = surfaceView(for: target) else { return false }
            onMain {
                NotificationCenter.default.post(name: .ghosttyBellDidRing, object: surfaceView)
            }

        case GHOSTTY_ACTION_SELECTION_CHANGED:
            guard let surfaceView = surfaceView(for: target) else { return false }
            onMain {
                NotificationCenter.default.post(name: .ghosttySelectionDidChange, object: surfaceView)
            }

        case GHOSTTY_ACTION_READONLY:
            guard let surfaceView = surfaceView(for: target) else { return false }
            let readonly = action.action.readonly == GHOSTTY_READONLY_ON
            onMain {
                NotificationCenter.default.post(
                    name: .ghosttyDidChangeReadonly,
                    object: surfaceView,
                    userInfo: [SwiftUI.Notification.Name.ReadonlyKey: readonly]
                )
            }

        case GHOSTTY_ACTION_PROGRESS_REPORT:
            guard let surfaceView = surfaceView(for: target) else { return false }
            let host = hostApp(from: ghostty_app_userdata(app))
            let progressReport = Ghostty.Action.ProgressReport(c: action.action.progress_report)
            onMain {
                guard host.config.progressStyle else {
                    surfaceView.progressReport = nil
                    return
                }
                if progressReport.state == .remove {
                    surfaceView.progressReport = nil
                } else {
                    surfaceView.progressReport = progressReport
                }
            }

        case GHOSTTY_ACTION_SECURE_INPUT:
            // Surface-scoped secure input only (upstream L1575-1607); the
            // app-target variant needs AppDelegate plumbing we don't have.
            guard let mode = Ghostty.SetSecureInput.from(action.action.secure_input) else { return false }
            guard let surfaceView = surfaceView(for: target) else { return false }
            let host = hostApp(from: ghostty_app_userdata(app))
            onMain {
                guard host.config.autoSecureInput else { return }
                switch mode {
                case .on: surfaceView.passwordInput = true
                case .off: surfaceView.passwordInput = false
                case .toggle: surfaceView.passwordInput = !surfaceView.passwordInput
                }
            }

        case GHOSTTY_ACTION_SIZE_LIMIT:
            // Accepted but nothing to do: Codevisor's panel controls sizing.
            break

        case GHOSTTY_ACTION_OPEN_URL:
            // Cmd+click on a detected link (an auth flow's sign-in URL, a
            // dev server address in a shell). Upstream also handles .html
            // payloads by writing a temp file; Codevisor only opens real
            // URLs and reports anything else unsupported.
            let payload = Ghostty.Action.OpenURL(c: action.action.open_url)
            guard payload.kind == .text, let url = URL(string: payload.url) else { return false }
            onMain { NSWorkspace.shared.open(url) }

        default:
            // Window/tab/split/app-management actions Codevisor does not
            // support (NEW_WINDOW, NEW_TAB, NEW_SPLIT, GOTO_*, TOGGLE_*,
            // INSPECTOR, QUIT, OPEN_*, UNDO/REDO, search UI, ...).
            return false
        }

        return true
    }

    /// Resolves the surface view for a surface-targeted action.
    nonisolated private static func surfaceView(for target: ghostty_target_s) -> Ghostty.SurfaceView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE else { return nil }
        guard let surface = target.target.surface else { return nil }
        return surfaceView(from: surface)
    }
}
