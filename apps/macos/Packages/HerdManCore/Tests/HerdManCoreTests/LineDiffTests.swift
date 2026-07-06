import Foundation
import Testing
@testable import HerdManCore

@Suite("LineDiff")
struct LineDiffTests {
    @Test("Empty old text marks every line added")
    func creation() {
        let rows = LineDiff.rows(old: nil, new: "one\ntwo\n")
        #expect(rows.map(\.kind) == [.added, .added])
        #expect(rows.map(\.newLine) == [1, 2])
        #expect(rows.allSatisfy { $0.oldLine == nil })
        #expect(LineDiff.totals(old: nil, new: "one\ntwo\n") == LineDiff.Totals(added: 2, removed: 0))
    }

    @Test("Deletion-only diffs keep old line numbers")
    func deletion() {
        let rows = LineDiff.rows(old: "one\ntwo\nthree\n", new: "one\nthree\n")
        #expect(rows.map(\.kind) == [.context, .removed, .context])
        #expect(rows[1].oldLine == 2)
        #expect(rows[1].newLine == nil)
        #expect(rows[1].text == "two")
    }

    @Test("Replacements emit removals immediately before their additions")
    func replacementHunkOrder() {
        let rows = LineDiff.rows(
            old: "keep\nold-a\nold-b\nkeep2\n",
            new: "keep\nnew-a\nkeep2\n"
        )
        #expect(rows.map(\.kind) == [.context, .removed, .removed, .added, .context])
        #expect(rows.map(\.text) == ["keep", "old-a", "old-b", "new-a", "keep2"])
        #expect(rows[3].newLine == 2)
        #expect(rows[4].oldLine == 4)
        #expect(rows[4].newLine == 3)
    }

    @Test("Duplicate lines are counted individually (the set-diff failure case)")
    func duplicates() {
        let totals = LineDiff.totals(old: "x\n", new: "x\nx\nx\n")
        #expect(totals == LineDiff.Totals(added: 2, removed: 0))
        let rows = LineDiff.rows(old: "x\n", new: "x\nx\nx\n")
        #expect(rows.filter { $0.kind == .added }.count == 2)
        #expect(rows.filter { $0.kind == .context }.count == 1)
    }

    @Test("Identical texts produce only context rows")
    func identical() {
        let rows = LineDiff.rows(old: "a\nb\n", new: "a\nb\n")
        #expect(rows.allSatisfy { $0.kind == .context })
        #expect(rows.map(\.oldLine) == [1, 2])
        #expect(rows.map(\.newLine) == [1, 2])
        #expect(LineDiff.totals(old: "a\nb\n", new: "a\nb\n") == LineDiff.Totals(added: 0, removed: 0))
    }

    @Test("Trailing newlines do not create phantom lines")
    func trailingNewline() {
        #expect(LineDiff.rows(old: "a", new: "a\n").allSatisfy { $0.kind == .context })
        #expect(LineDiff.totals(old: "", new: "") == LineDiff.Totals(added: 0, removed: 0))
    }

    @Test("Dedent strips the indent shared across old and new jointly")
    func dedentJoint() {
        let (old, new) = LineDiff.dedent(
            old: "        if a {\n            b()\n        }\n",
            new: "        if a, c {\n            b()\n        }\n"
        )
        #expect(old == "if a {\n    b()\n}\n")
        #expect(new == "if a, c {\n    b()\n}\n")
    }

    @Test("Dedent uses the shallowest line of either side as the floor")
    func dedentShallowestFloor() {
        // Old is deeper than new everywhere; only new's shallowest indent
        // may be stripped, or the sides would fall out of column alignment.
        let (old, new) = LineDiff.dedent(old: "        deep\n", new: "    shallow\n        deep\n")
        #expect(old == "    deep\n")
        #expect(new == "shallow\n    deep\n")
    }

    @Test("Dedent handles tabs, ignores blank lines, and empties whitespace-only lines")
    func dedentTabsAndBlanks() {
        let (old, new) = LineDiff.dedent(old: nil, new: "\t\tone\n\n   \n\t\ttwo\n")
        #expect(old == nil)
        #expect(new == "one\n\n\ntwo\n")
    }

    @Test("Dedent leaves unindented and mixed-indent text untouched")
    func dedentNoCommonIndent() {
        let mixed = "    spaces\n\ttab\n"
        let (old, new) = LineDiff.dedent(old: "top\n    nested\n", new: mixed)
        #expect(old == "top\n    nested\n")
        #expect(new == mixed)
    }
}
