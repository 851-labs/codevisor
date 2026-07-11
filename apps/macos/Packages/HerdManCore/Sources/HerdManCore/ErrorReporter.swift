import Foundation
import Observation

/// The app-level surface for errors that have no natural home in the UI —
/// background sync failures, persistence write errors, cleanup that silently
/// mattered. Reports render as transient banners at the top of the window.
///
/// Errors that DO have a natural home (a session turn, a settings sheet, an
/// attachment chip) should be surfaced there instead, next to where the
/// failure happened; this reporter is the fallback, not the default.
///
/// Copy follows the HIG: say what happened and what the user can do about it,
/// in plain language, without blame or bare error codes.
@MainActor
@Observable
public final class ErrorReporter {
    public struct Entry: Identifiable, Equatable, Sendable {
        public let id: UUID
        /// Short statement of what went wrong ("Couldn't save your settings").
        public let title: String
        /// Optional detail: why, and what to do next.
        public let message: String?

        public init(id: UUID = UUID(), title: String, message: String? = nil) {
            self.id = id
            self.title = title
            self.message = message
        }
    }

    public static let shared = ErrorReporter()

    /// Oldest first; the banner layer renders these top-down.
    public private(set) var entries: [Entry] = []

    /// How long a banner stays up before dismissing itself. Errors here are
    /// informational (the failure already happened and has a recovery path or
    /// none at all), so auto-dismissal is appropriate per the HIG — anything
    /// requiring a decision must use an alert at the call site instead.
    public var autoDismissDelay: Duration = .seconds(10)
    /// Newest wins once the stack is full; older banners drop off.
    public var maxVisible = 3

    private var dismissTasks: [UUID: Task<Void, Never>] = [:]

    public init() {}

    /// Reports an error with pre-written, human-readable copy.
    public func report(_ title: String, message: String? = nil) {
        Log.surfaced.error("\(title, privacy: .public)\(message.map { ": \($0)" } ?? "", privacy: .public)")
        // Identical back-to-back reports (e.g. every save failing the same
        // way) refresh the existing banner instead of stacking duplicates.
        if let existing = entries.last, existing.title == title, existing.message == message {
            scheduleDismissal(of: existing.id)
            return
        }
        let entry = Entry(title: title, message: message)
        entries.append(entry)
        while entries.count > maxVisible {
            dismiss(entries[0].id)
        }
        scheduleDismissal(of: entry.id)
    }

    /// Reports an underlying error beneath a human-readable headline. The
    /// detail line prefers the error's own user-facing description.
    public func report(_ title: String, error: any Error) {
        report(title, message: Self.userFacingMessage(for: error))
    }

    public func dismiss(_ id: UUID) {
        dismissTasks[id]?.cancel()
        dismissTasks[id] = nil
        entries.removeAll { $0.id == id }
    }

    public func dismissAll() {
        for entry in entries { dismissTasks[entry.id]?.cancel() }
        dismissTasks = [:]
        entries = []
    }

    private func scheduleDismissal(of id: UUID) {
        dismissTasks[id]?.cancel()
        let delay = autoDismissDelay
        dismissTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.dismiss(id)
        }
    }

    /// Best human-readable line for an arbitrary error. Delegates to
    /// `serverErrorMessage`, the app's one formatter for turning errors into
    /// HIG-style copy (server body sentences, friendly connection failures,
    /// LocalizedError descriptions, system-provided messages).
    public static func userFacingMessage(for error: any Error) -> String {
        serverErrorMessage(error)
    }
}
