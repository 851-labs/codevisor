import Foundation
import Observation

/// Drives the Finder-style remote folder browser: a stack of columns (one per
/// descended directory), each backed by the server's `/v1/fs/list` endpoint.
///
/// Navigation semantics mirror NSOpenPanel's column view:
/// - selecting an entry in a column truncates everything to its right and
///   loads the entry's children into a fresh trailing column;
/// - "up" prepends the parent directory as a new leftmost column with the old
///   first column preselected, so ⌘↑ never loses context;
/// - the chosen folder is the deepest selection (which is always the path of
///   the deepest column), falling back to the browse root.
///
/// Listings are cached per (path, showHidden) for the lifetime of the sheet,
/// so revisiting a column is instant even over a slow tunnel. A generation
/// counter guards every in-flight fetch: any mutation that rebuilds the
/// column stack invalidates responses that were requested for the old stack.
@MainActor
@Observable
public final class RemoteDirectoryBrowserModel {
    /// Fetches one directory listing. `path == nil` means the server's home.
    public typealias Lister = @Sendable (_ path: String?, _ showHidden: Bool) async throws -> ServerFsListing

    public struct Column: Identifiable, Equatable, Sendable {
        /// The requested directory path; stable identity for scroll targets.
        public let path: String
        public var listing: ServerFsListing?
        public var errorMessage: String?
        public var selectedEntryPath: String?
        public var isLoading = false

        public var id: String { path }

        public init(path: String) {
            self.path = path
        }
    }

    public private(set) var columns: [Column] = []
    public private(set) var showHidden = false
    /// The server-resolved home directory, learned from the first load.
    /// Sidebar "Home" and the initial breadcrumb hang off this.
    public private(set) var homePath: String?
    /// Error for the go-to-folder field only; column errors live on columns.
    public private(set) var goToError: String?

    private let list: Lister
    private let machineName: String
    private var cache: [String: ServerFsListing] = [:]
    private var generation = 0

    public init(machineName: String, list: @escaping Lister) {
        self.machineName = machineName
        self.list = list
    }

    // MARK: - Derived state

    /// The folder the Choose button acts on: the deepest selection wins,
    /// otherwise the current browse root. Nil until the first load resolves.
    public var chosenPath: String? {
        for column in columns.reversed() {
            if let selected = column.selectedEntryPath { return selected }
        }
        return columns.first?.listing?.path
    }

    /// Ancestor paths of the current browse root, deepest first, for the
    /// breadcrumb popup. Includes the root column itself.
    public var breadcrumb: [String] {
        guard let firstPath = columns.first?.listing?.path ?? columns.first.map(\.path) else { return [] }
        var paths = [firstPath]
        var current = firstPath
        while current != "/", !current.isEmpty {
            let parent = (current as NSString).deletingLastPathComponent
            guard parent != current, !parent.isEmpty else { break }
            paths.append(parent)
            current = parent
        }
        return paths
    }

    /// Whether anything above the current leftmost column exists to walk up to.
    public var canGoUp: Bool {
        columns.first?.listing?.parent != nil
    }

    // MARK: - Navigation

    /// Loads the browse root (the server's home directory).
    public func loadInitial() async {
        await open(nil)
    }

    /// Resets the browser to a single column at `path` (nil = server home).
    /// Used by the sidebar, breadcrumb, and recents. Failures render inside
    /// the column, keeping the sidebar as the recovery path.
    public func open(_ path: String?) async {
        generation += 1
        let requestGeneration = generation
        var column = Column(path: path ?? "~")
        column.isLoading = true
        columns = [column]
        goToError = nil
        do {
            let listing = try await fetch(path: path, showHidden: showHidden)
            guard generation == requestGeneration else { return }
            columns = [resolvedColumn(for: listing)]
            if path == nil { homePath = listing.path }
        } catch {
            guard generation == requestGeneration else { return }
            columns[0].isLoading = false
            columns[0].errorMessage = Self.guidance(
                code: serverErrorCode(error),
                fallback: serverErrorMessage(error),
                machineName: machineName
            )
        }
    }

    /// Selects `entryPath` inside the column identified by `columnPath`:
    /// truncates deeper columns and loads the entry's children to the right.
    public func select(_ entryPath: String, inColumn columnPath: String) async {
        guard let index = columns.firstIndex(where: { $0.path == columnPath }) else { return }
        if columns[index].selectedEntryPath == entryPath,
           columns.count > index + 1,
           columns[index + 1].path == entryPath {
            return // Re-click of the current selection; child column is live.
        }
        generation += 1
        let requestGeneration = generation
        columns[index].selectedEntryPath = entryPath
        columns.removeSubrange((index + 1)...)
        var child = Column(path: entryPath)
        child.isLoading = true
        columns.append(child)
        do {
            let listing = try await fetch(path: entryPath, showHidden: showHidden)
            guard generation == requestGeneration else { return }
            columns[columns.count - 1] = resolvedColumn(for: listing)
        } catch {
            guard generation == requestGeneration else { return }
            columns[columns.count - 1].isLoading = false
            columns[columns.count - 1].errorMessage = Self.guidance(
                code: serverErrorCode(error),
                fallback: serverErrorMessage(error),
                machineName: machineName
            )
        }
    }

    /// Walks up one level by prepending the parent as the new leftmost
    /// column, with the previous root preselected — mirroring Finder, where
    /// going up never discards the columns you came from.
    public func prependParent() async {
        guard let first = columns.first, let parent = first.listing?.parent else { return }
        generation += 1
        let requestGeneration = generation
        var column = Column(path: parent)
        column.isLoading = true
        column.selectedEntryPath = first.listing?.path
        columns.insert(column, at: 0)
        do {
            let listing = try await fetch(path: parent, showHidden: showHidden)
            guard generation == requestGeneration else { return }
            var resolved = resolvedColumn(for: listing)
            resolved.selectedEntryPath = columns[0].selectedEntryPath
            columns[0] = resolved
        } catch {
            guard generation == requestGeneration else { return }
            // A parent we can't list isn't useful context; drop it and stay put.
            columns.removeFirst()
        }
    }

    /// Validates and jumps to a typed path (⇧⌘G). On failure the current
    /// columns are untouched and `goToError` carries actionable guidance, so
    /// a typo is always recoverable. Returns true when navigation happened.
    @discardableResult
    public func goToPath(_ raw: String) async -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            goToError = Self.guidance(code: "invalid_path", fallback: "", machineName: machineName)
            return false
        }
        do {
            let listing = try await fetch(path: trimmed, showHidden: showHidden)
            generation += 1
            columns = [resolvedColumn(for: listing)]
            goToError = nil
            return true
        } catch {
            goToError = Self.guidance(
                code: serverErrorCode(error),
                fallback: serverErrorMessage(error),
                machineName: machineName
            )
            return false
        }
    }

    public func clearGoToError() {
        goToError = nil
    }

    /// Toggles hidden folders and reloads every column under the new flag.
    /// Selections survive when the selected folder is still listed; a
    /// selection that pointed at a now-hidden folder truncates from there.
    public func setShowHidden(_ value: Bool) async {
        guard value != showHidden else { return }
        showHidden = value
        generation += 1
        let requestGeneration = generation
        let paths = columns.map(\.path)
        let selections = columns.map(\.selectedEntryPath)
        var reloaded: [Column] = []
        for (index, path) in paths.enumerated() {
            do {
                let listing = try await fetch(path: path, showHidden: value)
                guard generation == requestGeneration else { return }
                var column = resolvedColumn(for: listing)
                if let selected = selections[index],
                   listing.entries.contains(where: { $0.path == selected }) {
                    column.selectedEntryPath = selected
                    reloaded.append(column)
                } else {
                    reloaded.append(column)
                    break // Deeper columns hang off a folder no longer shown.
                }
            } catch {
                guard generation == requestGeneration else { return }
                break
            }
        }
        if !reloaded.isEmpty {
            columns = reloaded
        }
    }

    // MARK: - Internals

    private func resolvedColumn(for listing: ServerFsListing) -> Column {
        var column = Column(path: listing.path)
        column.listing = listing
        return column
    }

    private func fetch(path: String?, showHidden: Bool) async throws -> ServerFsListing {
        let key = "\(showHidden ? "h" : "v"):\(path ?? "~")"
        if let cached = cache[key] { return cached }
        let listing = try await list(path, showHidden)
        cache[key] = listing
        // Also key by the resolved path so "~" and "/home/user" share an entry.
        cache["\(showHidden ? "h" : "v"):\(listing.path)"] = listing
        return listing
    }

    /// Actionable messages for the server's classified `fs/list` failures.
    /// The fallback is the server's own error sentence (or the connection
    /// failure message).
    public static func guidance(code: String?, fallback: String, machineName: String) -> String {
        switch code {
        case "not_found":
            return "That folder doesn't exist on \(machineName). Check the path and try again."
        case "permission_denied":
            return "Codevisor on \(machineName) isn't allowed to read that folder. "
                + "Pick another folder, or adjust its permissions on the machine."
        case "not_a_directory":
            return "That path is a file, not a folder."
        case "invalid_path":
            return "Enter an absolute path (starting with /), or ~ for the home folder."
        default:
            return fallback
        }
    }
}
