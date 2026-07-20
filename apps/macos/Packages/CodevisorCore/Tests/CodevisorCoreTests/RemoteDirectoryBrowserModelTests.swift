import Foundation
import Testing

@testable import CodevisorCore

/// A scripted remote filesystem: paths map to listings, failures map to the
/// server's classified HTTP errors. Counts fetches so cache behavior is
/// observable.
private final class FakeRemoteFs: @unchecked Sendable {
    private let lock = NSLock()
    private var listings: [String: ServerFsListing]
    private var hiddenListings: [String: ServerFsListing]
    private var failures: [String: CodevisorServerClientError]
    private var _fetchedPaths: [String] = []
    let homePath: String

    init(
        homePath: String,
        listings: [String: ServerFsListing],
        hiddenListings: [String: ServerFsListing] = [:],
        failures: [String: CodevisorServerClientError] = [:]
    ) {
        self.homePath = homePath
        self.listings = listings
        self.hiddenListings = hiddenListings
        self.failures = failures
    }

    var fetchedPaths: [String] {
        lock.withLock { _fetchedPaths }
    }

    func lister() -> RemoteDirectoryBrowserModel.Lister {
        { [self] path, showHidden in
            let resolved = path ?? homePath
            lock.withLock { _fetchedPaths.append(resolved) }
            if let failure = lock.withLock({ failures[resolved] }) {
                throw failure
            }
            let listing = lock.withLock {
                showHidden ? (hiddenListings[resolved] ?? listings[resolved]) : listings[resolved]
            }
            guard let listing else {
                throw CodevisorServerClientError.httpStatus(
                    404, #"{"error":"No such directory: \#(resolved)","code":"not_found"}"#
                )
            }
            return listing
        }
    }
}

private func listing(_ path: String, children: [String], gitRepos: Set<String> = []) -> ServerFsListing {
    ServerFsListing(
        path: path,
        parent: path == "/" ? nil : (path as NSString).deletingLastPathComponent,
        entries: children.map { name in
            ServerFsEntry(
                name: name,
                path: path == "/" ? "/\(name)" : "\(path)/\(name)",
                isGitRepo: gitRepos.contains(name)
            )
        }
    )
}

@MainActor
@Suite("RemoteDirectoryBrowserModel")
struct RemoteDirectoryBrowserModelTests {
    /// A small tree: /home/user{src{alpha,beta},docs}, plus a hidden variant.
    private func makeFs() -> FakeRemoteFs {
        FakeRemoteFs(
            homePath: "/home/user",
            listings: [
                "/": listing("/", children: ["home"]),
                "/home": listing("/home", children: ["user"]),
                "/home/user": listing("/home/user", children: ["docs", "src"]),
                "/home/user/src": listing("/home/user/src", children: ["alpha", "beta"], gitRepos: ["alpha"]),
                "/home/user/src/alpha": listing("/home/user/src/alpha", children: []),
                "/home/user/src/beta": listing("/home/user/src/beta", children: []),
                "/home/user/docs": listing("/home/user/docs", children: [])
            ]
        )
    }

    private func makeModel(_ fs: FakeRemoteFs) -> RemoteDirectoryBrowserModel {
        RemoteDirectoryBrowserModel(machineName: "devbox", list: fs.lister())
    }

    @Test("Initial load shows home as the single column and learns homePath")
    func initialLoad() async {
        let model = makeModel(makeFs())
        await model.loadInitial()
        #expect(model.columns.count == 1)
        #expect(model.columns[0].listing?.path == "/home/user")
        #expect(model.homePath == "/home/user")
        #expect(model.chosenPath == "/home/user")
        #expect(model.canGoUp)
    }

    @Test("Selecting an entry appends a child column and chosenPath follows the selection")
    func selectAppendsChild() async {
        let model = makeModel(makeFs())
        await model.loadInitial()
        await model.select("/home/user/src", inColumn: "/home/user")
        #expect(model.columns.map(\.path) == ["/home/user", "/home/user/src"])
        #expect(model.columns[0].selectedEntryPath == "/home/user/src")
        #expect(model.columns[1].listing?.entries.map(\.name) == ["alpha", "beta"])
        #expect(model.chosenPath == "/home/user/src")
    }

    @Test("Re-selecting in an earlier column truncates deeper columns")
    func reselectTruncates() async {
        let model = makeModel(makeFs())
        await model.loadInitial()
        await model.select("/home/user/src", inColumn: "/home/user")
        await model.select("/home/user/src/alpha", inColumn: "/home/user/src")
        #expect(model.columns.count == 3)
        await model.select("/home/user/docs", inColumn: "/home/user")
        #expect(model.columns.map(\.path) == ["/home/user", "/home/user/docs"])
        #expect(model.chosenPath == "/home/user/docs")
    }

    @Test("Re-clicking the current selection is a no-op")
    func reselectSameEntryIsNoOp() async {
        let fs = makeFs()
        let model = makeModel(fs)
        await model.loadInitial()
        await model.select("/home/user/src", inColumn: "/home/user")
        let fetchCount = fs.fetchedPaths.count
        await model.select("/home/user/src", inColumn: "/home/user")
        #expect(fs.fetchedPaths.count == fetchCount)
        #expect(model.columns.count == 2)
    }

    @Test("Selecting a folder that fails to list keeps the error inside its column")
    func selectFailureShowsColumnError() async {
        let fs = FakeRemoteFs(
            homePath: "/home/user",
            listings: ["/home/user": listing("/home/user", children: ["locked"])],
            failures: [
                "/home/user/locked": .httpStatus(
                    403, #"{"error":"Permission denied","code":"permission_denied"}"#
                )
            ]
        )
        let model = makeModel(fs)
        await model.loadInitial()
        await model.select("/home/user/locked", inColumn: "/home/user")
        #expect(model.columns.count == 2)
        #expect(model.columns[1].errorMessage?.contains("isn't allowed to read") == true)
        // The unlistable folder is still the selection, so it can be chosen;
        // the server remains the authority on whether it's usable.
        #expect(model.chosenPath == "/home/user/locked")
    }

    @Test("prependParent adds the parent as the leftmost column with the old root selected")
    func prependParent() async {
        let model = makeModel(makeFs())
        await model.loadInitial()
        await model.prependParent()
        #expect(model.columns.map(\.path) == ["/home", "/home/user"])
        #expect(model.columns[0].selectedEntryPath == "/home/user")
        // chosenPath is unchanged: the deepest selection still wins.
        #expect(model.chosenPath == "/home/user")
    }

    @Test("prependParent at the filesystem root is a no-op")
    func prependParentAtRoot() async {
        let model = makeModel(makeFs())
        await model.loadInitial()
        await model.open("/")
        #expect(!model.canGoUp)
        await model.prependParent()
        #expect(model.columns.map(\.path) == ["/"])
    }

    @Test("goToPath jumps on success and resets the column stack")
    func goToPathSuccess() async {
        let model = makeModel(makeFs())
        await model.loadInitial()
        await model.select("/home/user/src", inColumn: "/home/user")
        let moved = await model.goToPath("  /home/user/docs  ")
        #expect(moved)
        #expect(model.columns.map(\.path) == ["/home/user/docs"])
        #expect(model.goToError == nil)
    }

    @Test("goToPath failure keeps the current columns and reports guidance")
    func goToPathFailure() async {
        let model = makeModel(makeFs())
        await model.loadInitial()
        let moved = await model.goToPath("/home/user/missing")
        #expect(!moved)
        #expect(model.columns.map(\.path) == ["/home/user"])
        #expect(model.goToError?.contains("doesn't exist on devbox") == true)
    }

    @Test("goToPath rejects empty input with path guidance")
    func goToPathEmpty() async {
        let model = makeModel(makeFs())
        await model.loadInitial()
        let moved = await model.goToPath("   ")
        #expect(!moved)
        #expect(model.goToError?.contains("absolute path") == true)
    }

    @Test("Revisiting a directory hits the cache instead of refetching")
    func cacheAvoidsRefetch() async {
        let fs = makeFs()
        let model = makeModel(fs)
        await model.loadInitial()
        await model.select("/home/user/src", inColumn: "/home/user")
        await model.select("/home/user/docs", inColumn: "/home/user")
        let fetchCount = fs.fetchedPaths.count
        await model.select("/home/user/src", inColumn: "/home/user")
        #expect(fs.fetchedPaths.count == fetchCount)
        #expect(model.columns[1].listing?.path == "/home/user/src")
    }

    @Test("Toggling hidden folders reloads every column and keeps surviving selections")
    func showHiddenReloads() async {
        let fs = FakeRemoteFs(
            homePath: "/home/user",
            listings: [
                "/home/user": listing("/home/user", children: ["docs", "src"]),
                "/home/user/src": listing("/home/user/src", children: ["alpha"])
            ],
            hiddenListings: [
                "/home/user": listing("/home/user", children: [".config", "docs", "src"]),
                "/home/user/src": listing("/home/user/src", children: [".git", "alpha"])
            ]
        )
        let model = makeModel(fs)
        await model.loadInitial()
        await model.select("/home/user/src", inColumn: "/home/user")
        await model.setShowHidden(true)
        #expect(model.showHidden)
        #expect(model.columns.map(\.path) == ["/home/user", "/home/user/src"])
        #expect(model.columns[0].listing?.entries.map(\.name) == [".config", "docs", "src"])
        #expect(model.columns[0].selectedEntryPath == "/home/user/src")
        #expect(model.columns[1].listing?.entries.map(\.name) == [".git", "alpha"])
        #expect(model.chosenPath == "/home/user/src")
    }

    @Test("Toggling hidden truncates below a selection that disappeared")
    func showHiddenTruncatesDeadSelection() async {
        let fs = FakeRemoteFs(
            homePath: "/home/user",
            // `.work` only exists in the hidden view: turning hidden *off*
            // while browsing inside it must truncate back to home.
            listings: [
                "/home/user": listing("/home/user", children: ["src"]),
                "/home/user/.work": listing("/home/user/.work", children: [])
            ],
            hiddenListings: [
                "/home/user": listing("/home/user", children: [".work", "src"])
            ]
        )
        let model = makeModel(fs)
        await model.loadInitial()
        await model.setShowHidden(true)
        await model.select("/home/user/.work", inColumn: "/home/user")
        #expect(model.columns.count == 2)
        await model.setShowHidden(false)
        #expect(model.columns.map(\.path) == ["/home/user"])
        #expect(model.columns[0].selectedEntryPath == nil)
        #expect(model.chosenPath == "/home/user")
    }

    @Test("open failure renders guidance inside the column")
    func openFailure() async {
        let fs = FakeRemoteFs(
            homePath: "/home/user",
            listings: ["/home/user": listing("/home/user", children: [])]
        )
        let model = makeModel(fs)
        await model.loadInitial()
        await model.open("/vanished")
        #expect(model.columns.count == 1)
        #expect(model.columns[0].errorMessage?.contains("doesn't exist on devbox") == true)
        #expect(model.chosenPath == nil)
    }

    @Test("Breadcrumb lists the browse root and its ancestors, deepest first")
    func breadcrumbAncestors() async {
        let model = makeModel(makeFs())
        await model.loadInitial()
        #expect(model.breadcrumb == ["/home/user", "/home", "/"])
    }

    @Test("Classified errors map to actionable guidance")
    func guidanceMessages() {
        typealias Model = RemoteDirectoryBrowserModel
        #expect(Model.guidance(code: "not_found", fallback: "x", machineName: "devbox")
            .contains("doesn't exist on devbox"))
        #expect(Model.guidance(code: "permission_denied", fallback: "x", machineName: "devbox")
            .contains("isn't allowed to read"))
        #expect(Model.guidance(code: "not_a_directory", fallback: "x", machineName: "devbox")
            == "That path is a file, not a folder.")
        #expect(Model.guidance(code: "invalid_path", fallback: "x", machineName: "devbox")
            .contains("absolute path"))
        #expect(Model.guidance(code: nil, fallback: "server said no", machineName: "devbox")
            == "server said no")
    }
}

@MainActor
@Suite("RemoteBrowserRecentsStore")
struct RemoteBrowserRecentsStoreTests {
    private func makeStore() -> (RemoteBrowserRecentsStore, UserDefaults) {
        let suite = "codevisor-recents-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (RemoteBrowserRecentsStore(defaults: defaults), defaults)
    }

    @Test("Records are most-recent-first, deduplicated, and capped")
    func recordOrdering() {
        let (store, _) = makeStore()
        for index in 1...8 {
            store.record("/p/\(index)", forMachine: "devbox")
        }
        store.record("/p/5", forMachine: "devbox")
        let recents = store.recents(forMachine: "devbox")
        #expect(recents.first == "/p/5")
        #expect(recents.count == 6)
        #expect(recents.filter { $0 == "/p/5" }.count == 1)
    }

    @Test("Recents are scoped per machine")
    func perMachineScope() {
        let (store, _) = makeStore()
        store.record("/a", forMachine: "devbox")
        store.record("/b", forMachine: "buildbox")
        #expect(store.recents(forMachine: "devbox") == ["/a"])
        #expect(store.recents(forMachine: "buildbox") == ["/b"])
    }

    @Test("Remove deletes a single path")
    func removePath() {
        let (store, _) = makeStore()
        store.record("/a", forMachine: "devbox")
        store.record("/b", forMachine: "devbox")
        store.remove("/a", forMachine: "devbox")
        #expect(store.recents(forMachine: "devbox") == ["/b"])
    }
}
