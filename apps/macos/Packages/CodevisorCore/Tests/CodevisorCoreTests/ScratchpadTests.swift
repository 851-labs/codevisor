import Foundation
import Testing
@testable import CodevisorCore

@Suite("Scratchpad repository")
struct ScratchpadRepositoryTests {
    @Test("State round-trips with styled runs intact")
    func roundTrip() {
        let store = InMemoryStore()
        let repository = DefaultScratchpadRepository(store: store)
        let sessionId = UUID()
        #expect(repository.load(sessionId: sessionId) == nil)

        var text = AttributedString("bold and plain")
        var bold = AttributedString("bold")
        bold.inlinePresentationIntent = .stronglyEmphasized
        text.replaceSubrange(text.range(of: "bold")!, with: bold)
        let state = ScratchpadState(text: text, isVisible: true)
        repository.save(state, sessionId: sessionId)

        let reloaded = DefaultScratchpadRepository(store: store).load(sessionId: sessionId)
        #expect(reloaded == state)
    }

    @Test("Sessions don't cross-contaminate")
    func isolation() {
        let repository = DefaultScratchpadRepository(store: InMemoryStore())
        let first = UUID()
        let second = UUID()
        repository.save(ScratchpadState(text: AttributedString("one")), sessionId: first)
        repository.save(ScratchpadState(text: AttributedString("two")), sessionId: second)
        #expect(String(repository.load(sessionId: first)!.text.characters) == "one")
        #expect(String(repository.load(sessionId: second)!.text.characters) == "two")
    }

    @Test("Corrupted data decodes as nil")
    func corruptedData() {
        let sessionId = UUID()
        let store = InMemoryStore(storage: ["scratchpad.\(sessionId.uuidString)": Data("not json".utf8)])
        #expect(DefaultScratchpadRepository(store: store).load(sessionId: sessionId) == nil)
    }

    @Test("FileSystemStore writes one file per session")
    func fileSystemStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codevisor-scratchpad-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileSystemStore(directory: directory)
        let repository = DefaultScratchpadRepository(store: store)
        let sessionId = UUID()
        repository.save(ScratchpadState(text: AttributedString("notes"), isVisible: true), sessionId: sessionId)
        store.flushPendingWrites()

        let file = directory.appendingPathComponent("scratchpad.\(sessionId.uuidString).json")
        #expect(FileManager.default.fileExists(atPath: file.path))

        let reopened = DefaultScratchpadRepository(store: FileSystemStore(directory: directory))
        let reloaded = reopened.load(sessionId: sessionId)
        #expect(String(reloaded!.text.characters) == "notes")
        #expect(reloaded!.isVisible)
    }
}

@MainActor
@Suite("Scratchpad model")
struct ScratchpadModelTests {
    @Test("Text saves are debounced until flush")
    func debouncedSave() {
        let repository = DefaultScratchpadRepository(store: InMemoryStore())
        let model = ScratchpadModel(sessionId: UUID(), repository: repository)
        model.text = AttributedString("draft")
        #expect(repository.load(sessionId: model.sessionId) == nil)

        model.flush()
        #expect(String(repository.load(sessionId: model.sessionId)!.text.characters) == "draft")
    }

    @Test("Debounced save lands on its own")
    func debounceFires() async throws {
        let repository = DefaultScratchpadRepository(store: InMemoryStore())
        let model = ScratchpadModel(sessionId: UUID(), repository: repository)
        model.text = AttributedString("typed")
        try await Task.sleep(for: .milliseconds(900))
        #expect(String(repository.load(sessionId: model.sessionId)!.text.characters) == "typed")
    }

    @Test("Visibility persists immediately")
    func visibilitySavesSynchronously() {
        let repository = DefaultScratchpadRepository(store: InMemoryStore())
        let model = ScratchpadModel(sessionId: UUID(), repository: repository)
        model.toggle()
        #expect(model.isVisible)
        #expect(repository.load(sessionId: model.sessionId)?.isVisible == true)
    }

    @Test("A new model seeds from persisted state")
    func seedsFromRepository() {
        let repository = DefaultScratchpadRepository(store: InMemoryStore())
        let sessionId = UUID()
        repository.save(ScratchpadState(text: AttributedString("kept"), isVisible: true), sessionId: sessionId)

        let model = ScratchpadModel(sessionId: sessionId, repository: repository)
        #expect(String(model.text.characters) == "kept")
        #expect(model.isVisible)
    }
}

@Suite("Scratchpad text rules")
struct ScratchpadTextRulesTests {
    private func plain(_ transform: ScratchpadTextRules.Transform?) -> String? {
        transform.map { String($0.text.characters) }
    }

    // MARK: Return

    @Test("Return continues a bullet list")
    func returnContinuesBullet() {
        let result = ScratchpadTextRules.continueListOnReturn(text: AttributedString("• hi"), caretOffset: 4)
        #expect(plain(result) == "• hi\n• ")
        #expect(result?.caretOffset == 7)
    }

    @Test("Return mid-item splits into a new item")
    func returnSplitsItem() {
        let result = ScratchpadTextRules.continueListOnReturn(text: AttributedString("• hello"), caretOffset: 4)
        #expect(plain(result) == "• he\n• llo")
        #expect(result?.caretOffset == 7)
    }

    @Test("Return on an empty item exits the list")
    func returnExitsList() {
        let result = ScratchpadTextRules.continueListOnReturn(text: AttributedString("• a\n• "), caretOffset: 6)
        #expect(plain(result) == "• a\n")
        #expect(result?.caretOffset == 4)
    }

    @Test("Return outside a list is not handled")
    func returnOutsideList() {
        #expect(ScratchpadTextRules.continueListOnReturn(text: AttributedString("plain"), caretOffset: 5) == nil)
        // Caret inside the prefix: let the editor handle it.
        #expect(ScratchpadTextRules.continueListOnReturn(text: AttributedString("• hi"), caretOffset: 1) == nil)
    }

    // MARK: Autoformat

    @Test("Dash and star become bullets at line start")
    func autoformatBullet() {
        let dash = ScratchpadTextRules.applyAutoformat(text: AttributedString("- "), caretOffset: 2)
        #expect(plain(dash) == "• ")
        #expect(dash?.caretOffset == 2)

        let star = ScratchpadTextRules.applyAutoformat(text: AttributedString("a\n* "), caretOffset: 4)
        #expect(plain(star) == "a\n• ")
        #expect(star?.caretOffset == 4)
    }

    @Test("Shortcuts only fire at the start of a line")
    func autoformatOnlyAtLineStart() {
        #expect(ScratchpadTextRules.applyAutoformat(text: AttributedString("x- "), caretOffset: 3) == nil)
        #expect(ScratchpadTextRules.applyAutoformat(text: AttributedString("- x"), caretOffset: 3) == nil)
    }

    // MARK: Toggles

    @Test("Toggle bullet adds and removes the prefix")
    func toggleBullet() {
        let added = ScratchpadTextRules.toggleBullet(text: AttributedString("hello"), selection: 3 ..< 3)
        #expect(String(added.text.characters) == "• hello")
        #expect(added.caretOffset == 7)

        let removed = ScratchpadTextRules.toggleBullet(text: added.text, selection: 4 ..< 4)
        #expect(String(removed.text.characters) == "hello")
        #expect(removed.caretOffset == 5)
    }

    @Test("Toggle bullet over a mixed selection bullets every line")
    func toggleBulletMixedSelection() {
        let result = ScratchpadTextRules.toggleBullet(text: AttributedString("• a\nb\nc"), selection: 0 ..< 7)
        #expect(String(result.text.characters) == "• a\n• b\n• c")
    }
}
