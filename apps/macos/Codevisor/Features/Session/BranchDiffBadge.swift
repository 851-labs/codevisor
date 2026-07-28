import SwiftUI
import CodevisorUI
import CodevisorCore
import CoreServices

/// The top bar's `+x −y` counter for a session's working directory: everything
/// the current git branch changes relative to the repository's default branch
/// (merge-base), including uncommitted edits. Renders nothing when the
/// directory isn't a git checkout.
///
/// Refreshes are event-driven (FSEvents on the working tree) with a slow
/// heartbeat fallback — the old 3-second polling loop spawned 4–7 git
/// processes per tick, forever, per open session window.
struct BranchDiffBadge: View {
    let directory: URL

    @State private var totals: LineDiff.Totals?

    private var hasDiff: Bool {
        guard let totals else { return false }
        return totals.added > 0 || totals.removed > 0
    }

    var body: some View {
        HStack(spacing: 0) {
            // A `+0 −0` badge on a clean branch is noise — show the counter
            // only once there is an actual diff.
            if let totals, hasDiff {
                DiffCounter(totals: totals)
            }
        }
        // Hosted in a spacing-0 group beside the + button, so an empty badge
        // contributes NOTHING to the header layout; when showing, it brings
        // its own gap.
        .padding(.trailing, hasDiff ? 8 : 0)
        .task(id: directory) {
            // Initial compute plus a slow heartbeat: commits made in a git
            // worktree land in the external gitdir and emit no FSEvents under
            // the watched tree, so ref-only changes need a periodic sweep.
            guard !AppPreview.isRunning else { return }
            totals = nil
            while !Task.isCancelled {
                totals = await GitBranchDiff.totals(in: directory)
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .task(id: directory) {
            // Event-driven refresh: recompute when the working tree actually
            // changes. The stream's latency window coalesces edit bursts, and
            // `bufferingNewest(1)` guarantees at most ONE recompute is queued
            // no matter how many callbacks land while a sweep is running —
            // the default unbounded buffer turned an agent's edit storm into
            // an equal-length queue of sequential full git sweeps.
            guard !AppPreview.isRunning else { return }
            let changes = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { continuation in
                let watcher = DirectoryChangeWatcher(directory: directory) {
                    continuation.yield()
                }
                continuation.onTermination = { _ in watcher?.stop() }
            }
            for await _ in changes {
                totals = await GitBranchDiff.totals(in: directory)
                // Floor between event-driven sweeps while events keep coming;
                // everything arriving during the pause collapses into the one
                // buffered event consumed next, so the final state is never
                // missed — just batched.
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

/// A debounced FSEvents watcher over a directory tree. Changes inside `.git`
/// are ignored so the badge's own git invocations (which can refresh the
/// index) never re-trigger the refresh they came from.
private final class DirectoryChangeWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.codevisor.branch-diff-watch", qos: .utility)

    init?(directory: URL, onChange: @escaping @Sendable () -> Void) {
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info, count > 0 else { return }
            let watcher = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
            let pathList = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let relevant = pathList.contains { path in
                !path.contains("/.git/") && !path.hasSuffix("/.git")
            }
            if relevant { watcher.onChange() }
        }

        let box = CallbackBox(onChange: onChange)
        self.box = box
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5, // latency: coalesce bursts of file events into one callback
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagIgnoreSelf)
        ) else { return nil }
        self.stream = stream
        // Prune the two universally-irrelevant subtrees at the kernel level
        // instead of waking up to filter their paths in the callback. `.git`
        // never changes the working-tree diff by itself (and is also filtered
        // above); `node_modules` is gitignored everywhere and dominates event
        // volume during installs. Anything else (build dirs a repo might
        // track) still flows through normally.
        FSEventStreamSetExclusionPaths(stream, [
            directory.appendingPathComponent(".git").path,
            directory.appendingPathComponent("node_modules").path,
        ] as CFArray)
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    /// Keeps the change closure reachable from the C callback without
    /// retain-cycle gymnastics on the watcher itself.
    private final class CallbackBox {
        let onChange: @Sendable () -> Void
        init(onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
    }

    private var box: CallbackBox?

    func stop() {
        queue.sync {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    deinit {
        stop()
    }
}

/// Computes branch diff totals by shelling out to git off the main actor. Any
/// failure — not a repo, git missing, no commits yet — yields nil and the
/// badge stays hidden.
enum GitBranchDiff {
    /// Refs tried, in order, to find the default branch the session's branch
    /// diverged from; the first that resolves a merge-base with HEAD becomes
    /// the diff base. On the default branch itself the merge-base is HEAD, so
    /// the badge shows just the uncommitted changes.
    private static let baseRefs = ["origin/HEAD", "origin/main", "origin/master", "main", "master"]

    static func totals(in directory: URL) async -> LineDiff.Totals? {
        await Task.detached(priority: .utility) {
            let repoKey = directory.path
            // "Is a work tree" can only flip false→true (git init); a
            // vanished repo just makes the later git calls fail to nil. So a
            // positive answer is cached forever and a negative one re-probes.
            if !(await Cache.shared.isKnownWorkTree(repoKey)) {
                guard output(["rev-parse", "--is-inside-work-tree"], in: directory) == "true" else {
                    return nil
                }
                await Cache.shared.markWorkTree(repoKey)
            }
            // The merge-base can only move when HEAD moves — or when a fetch
            // updates the default branch, which the short TTL covers. This
            // replaces up to five `git merge-base` spawns per sweep with one
            // `rev-parse` in the steady state.
            let head = output(["rev-parse", "HEAD"], in: directory) ?? ""
            let base: String
            if !head.isEmpty, let cached = await Cache.shared.base(for: repoKey, head: head) {
                base = cached
            } else {
                base = baseRefs.lazy
                    .compactMap { output(["merge-base", "HEAD", $0], in: directory) }
                    .first { !$0.isEmpty } ?? "HEAD"
                if !head.isEmpty {
                    await Cache.shared.setBase(base, for: repoKey, head: head)
                }
            }
            // Base → working tree, so committed branch work and uncommitted
            // edits both count.
            guard let numstat = output(["diff", "--numstat", base], in: directory) else {
                return nil
            }
            var totals = parse(numstat)
            // `git diff` skips untracked files, but brand-new files are most
            // of what agent sessions produce — count their lines as additions.
            if let untracked = output(["ls-files", "--others", "--exclude-standard", "-z"], in: directory) {
                let paths = untracked.split(separator: "\u{0}").map(String.init)
                totals.added += await Cache.shared.untrackedLineTotal(
                    directory: directory,
                    repoKey: repoKey,
                    paths: paths
                )
            }
            return totals
        }.value
    }

    /// Per-repo memo shared by every badge and sweep. Everything cached here
    /// is verifiable staleness-free (work-tree flag, stat-keyed line counts)
    /// or bounded by a short TTL (merge-base after a fetch moves the default
    /// branch without HEAD moving).
    private actor Cache {
        static let shared = Cache()

        private struct BaseEntry {
            let head: String
            let base: String
            let resolvedAt: ContinuousClock.Instant
        }

        private struct LineCountEntry {
            let modified: Date
            let size: Int
            let lines: Int
        }

        private var knownWorkTrees: Set<String> = []
        private var bases: [String: BaseEntry] = [:]
        /// Keyed repo → untracked path → stat-fingerprinted count. Replaced
        /// wholesale per sweep, so files that stop being untracked fall out.
        private var lineCounts: [String: [String: LineCountEntry]] = [:]

        private static let baseTTL: Duration = .seconds(60)

        func isKnownWorkTree(_ key: String) -> Bool { knownWorkTrees.contains(key) }
        func markWorkTree(_ key: String) { knownWorkTrees.insert(key) }

        func base(for key: String, head: String) -> String? {
            guard let entry = bases[key],
                  entry.head == head,
                  ContinuousClock.now - entry.resolvedAt < Self.baseTTL else { return nil }
            return entry.base
        }

        func setBase(_ base: String, for key: String, head: String) {
            bases[key] = BaseEntry(head: head, base: base, resolvedAt: .now)
        }

        /// Sums line counts for the untracked set, re-reading only files whose
        /// (mtime, size) fingerprint moved since the last sweep — one `stat`
        /// instead of an mmap + full byte scan per unchanged file.
        func untrackedLineTotal(directory: URL, repoKey: String, paths: [String]) -> Int {
            let previous = lineCounts[repoKey] ?? [:]
            var fresh: [String: LineCountEntry] = [:]
            fresh.reserveCapacity(paths.count)
            var total = 0
            for path in paths {
                let url = directory.appendingPathComponent(path)
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                let modified = attributes?[.modificationDate] as? Date ?? .distantPast
                let size = (attributes?[.size] as? NSNumber)?.intValue ?? -1
                if let entry = previous[path], entry.modified == modified, entry.size == size {
                    fresh[path] = entry
                    total += entry.lines
                } else {
                    let lines = GitBranchDiff.lineCount(of: url)
                    fresh[path] = LineCountEntry(modified: modified, size: size, lines: lines)
                    total += lines
                }
            }
            lineCounts[repoKey] = fresh
            return total
        }
    }

    /// Lines in an untracked file; binary-looking or oversized files count as
    /// zero, matching how `--numstat` reports binaries.
    private static func lineCount(of file: URL) -> Int {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
              !data.isEmpty,
              data.count <= 4_000_000,
              !data.prefix(8192).contains(0) else {
            return 0
        }
        let newlines = data.count(where: { $0 == UInt8(ascii: "\n") })
        return data.last == UInt8(ascii: "\n") ? newlines : newlines + 1
    }

    /// Sums a `--numstat` listing (`added<TAB>removed<TAB>path` per line;
    /// binary files report `-` and count as zero).
    private static func parse(_ numstat: String) -> LineDiff.Totals {
        var totals = LineDiff.Totals(added: 0, removed: 0)
        for line in numstat.split(separator: "\n") {
            let fields = line.split(separator: "\t")
            guard fields.count >= 2 else { continue }
            totals.added += Int(fields[0]) ?? 0
            totals.removed += Int(fields[1]) ?? 0
        }
        return totals
    }

    /// Runs git and returns its trimmed stdout, or nil on any failure.
    private static func output(_ arguments: [String], in directory: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
