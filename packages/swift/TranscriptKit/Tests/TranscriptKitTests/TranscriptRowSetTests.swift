import CoreGraphics
import Foundation
import Testing
@testable import TranscriptKit

struct TranscriptRowSetTests {
    private typealias Row = TranscriptPresentationRow

    private func settled(_ id: UUID, height: CGFloat = 40, revision: Int = 0) -> Row {
        Row(id: .message(id), content: .error(""), estimatedHeight: height, measurementRevision: revision)
    }

    private func active(_ id: UUID, height: CGFloat = 60) -> Row {
        Row(id: .active(id), content: .error(""), estimatedHeight: height)
    }

    private func activeMarkdown(_ id: UUID, ordinal: Int, height: CGFloat = 20) -> Row {
        Row(
            id: .activeMarkdown(id, sourceID: "s", ordinal: ordinal, fragment: nil),
            content: .error(""),
            estimatedHeight: height
        )
    }

    private func settledResult(_ id: UUID, height: CGFloat = 40) -> Row {
        Row(id: .assistantResult(id), content: .error(""), estimatedHeight: height)
    }

    private func spacer(_ height: CGFloat) -> Row {
        Row(id: .bottomSpacer, content: .bottomSpacer(height), estimatedHeight: height)
    }

    // MARK: resolve

    @Test func resolveWithoutActivePlaceholderReturnsProjectedRows() {
        let rows = [settled(UUID()), settled(UUID())]
        let resolution = TranscriptRowSet.resolve(projectedRows: rows, activeRows: [])
        #expect(resolution.rows == rows)
        #expect(resolution.activeRange == nil)
    }

    @Test func resolveKeepsPlaceholderWhenActiveRowsBelongToAnotherMessage() {
        let turn = UUID()
        let rows = [settled(UUID()), active(turn), spacer(10)]
        let resolution = TranscriptRowSet.resolve(
            projectedRows: rows,
            activeRows: [activeMarkdown(UUID(), ordinal: 0)]
        )
        #expect(resolution.rows == rows)
        #expect(resolution.activeRange == 1..<2)
    }

    @Test func resolveSplicesActiveRowsOverPlaceholder() {
        let turn = UUID()
        let head = settled(UUID())
        let slices = [activeMarkdown(turn, ordinal: 0), activeMarkdown(turn, ordinal: 1)]
        let resolution = TranscriptRowSet.resolve(
            projectedRows: [head, active(turn), spacer(10)],
            activeRows: slices
        )
        #expect(resolution.rows.map(\.layoutKey) == [head, slices[0], slices[1], spacer(10)].map(\.layoutKey))
        #expect(resolution.activeRange == 1..<3)
    }

    // MARK: reversePrependCount

    @Test func reversePrependCountDetectsOlderHistoryPrepend() {
        let old = [settled(UUID()), settled(UUID())]
        let new = [settled(UUID()), settled(UUID()), settled(UUID())] + old
        #expect(TranscriptRowSet.reversePrependCount(from: old, to: new) == 3)
    }

    @Test func reversePrependCountRejectsOtherChanges() {
        let old = [settled(UUID()), settled(UUID())]
        #expect(TranscriptRowSet.reversePrependCount(from: [], to: old) == nil)
        #expect(TranscriptRowSet.reversePrependCount(from: old, to: old) == nil)
        #expect(TranscriptRowSet.reversePrependCount(from: old, to: old + [settled(UUID())]) == nil)
        #expect(TranscriptRowSet.reversePrependCount(from: old, to: [settled(UUID()), old[1], settled(UUID())]) == nil)
    }

    // MARK: geometryChanged

    @Test func geometryChangedIgnoresContentButTracksIdentityAndEstimates() {
        let id = UUID()
        let base = settled(id, height: 40, revision: 1)
        #expect(!TranscriptRowSet.geometryChanged(from: [base], to: [base]))
        #expect(TranscriptRowSet.geometryChanged(from: [base], to: [settled(id, height: 41, revision: 1)]))
        #expect(TranscriptRowSet.geometryChanged(from: [base], to: [settled(id, height: 40, revision: 2)]))
        #expect(TranscriptRowSet.geometryChanged(from: [base], to: [settled(UUID(), height: 40, revision: 1)]))
        #expect(TranscriptRowSet.geometryChanged(from: [base], to: [base, base]))
        let sameGeometryDifferentContent = Row(
            id: .message(id), content: .backgroundTask("x"), estimatedHeight: 40, measurementRevision: 1
        )
        #expect(!TranscriptRowSet.geometryChanged(from: [base], to: [sameGeometryDifferentContent]))
    }

    // MARK: replaceRows

    @Test func replaceRowsReturnsPreviousIndexAndRebuildsKeyIndex() {
        var set = TranscriptRowSet()
        let a = settled(UUID())
        let b = settled(UUID())
        #expect(set.replaceRows([a]).isEmpty)
        let previous = set.replaceRows([a, b])
        #expect(previous.keys.sorted() == [a.layoutKey])
        #expect(set.rows == [a, b])
        #expect(set.rowByKey[b.layoutKey] == b)
    }

    // MARK: replaceActiveRows

    @Test func replaceActiveRowsPatchesInPlaceWhenKeysAreStable() {
        let turn = UUID()
        let head = settled(UUID())
        var set = TranscriptRowSet()
        set.projectedRows = [head, active(turn), spacer(10)]
        let initial = [activeMarkdown(turn, ordinal: 0, height: 20), activeMarkdown(turn, ordinal: 1, height: 20)]
        #expect(
            set.replaceActiveRows(initial)
                == .rebuild(rows: TranscriptRowSet.resolve(projectedRows: set.projectedRows, activeRows: initial).rows))
        set.replaceRows(TranscriptRowSet.resolve(projectedRows: set.projectedRows, activeRows: initial).rows)

        let grown = [activeMarkdown(turn, ordinal: 0, height: 20), activeMarkdown(turn, ordinal: 1, height: 55)]
        let replacement = set.replaceActiveRows(grown)
        #expect(replacement == .inPlace(range: 1..<3, previousRows: initial))
        #expect(set.rows[2].estimatedHeight == 55)
        #expect(set.rowByKey[grown[1].layoutKey]?.estimatedHeight == 55)
        #expect(set.activeRows == grown)
        #expect(set.activeRowsRange == 1..<3)
    }

    @Test func replaceActiveRowsRequestsRebuildWhenSliceCountChanges() {
        let turn = UUID()
        var set = TranscriptRowSet()
        set.projectedRows = [settled(UUID()), active(turn)]
        let one = [activeMarkdown(turn, ordinal: 0)]
        _ = set.replaceActiveRows(one)
        set.replaceRows(TranscriptRowSet.resolve(projectedRows: set.projectedRows, activeRows: one).rows)

        let two = [activeMarkdown(turn, ordinal: 0), activeMarkdown(turn, ordinal: 1)]
        guard case let .rebuild(rows) = set.replaceActiveRows(two) else {
            Issue.record("expected rebuild")
            return
        }
        #expect(rows.count == 3)
        #expect(set.activeRowsRange == 1..<3)
        #expect(set.activeRows == two)
    }

    @Test func replaceActiveRowsRequestsRebuildWhenKeysDiffer() {
        let turn = UUID()
        var set = TranscriptRowSet()
        set.projectedRows = [active(turn)]
        let first = [activeMarkdown(turn, ordinal: 0)]
        _ = set.replaceActiveRows(first)
        set.replaceRows(TranscriptRowSet.resolve(projectedRows: set.projectedRows, activeRows: first).rows)

        let renumbered = [activeMarkdown(turn, ordinal: 7)]
        guard case .rebuild = set.replaceActiveRows(renumbered) else {
            Issue.record("expected rebuild")
            return
        }
    }

    // MARK: transferActiveHeightIfNeeded

    @Test func transfersActiveHeightOntoSingleSettledReplacementAsProvisional() {
        let turn = UUID()
        let activeRow = active(turn)
        let settledRow = settledResult(turn)
        var ledger = TranscriptMeasurementLedger()
        ledger.setExact(123, for: activeRow.layoutKey)

        TranscriptRowSet.transferActiveHeightIfNeeded(from: [activeRow], to: [settledRow], ledger: &ledger)

        #expect(ledger[settledRow.layoutKey] == 123)
        #expect(ledger.isStale(settledRow.layoutKey))
    }

    @Test func doesNotTransferWhenActiveSettlesUnderItsOwnKey() {
        // `.active(id)` and `.message(id)` share `message:<id>`: the settled
        // row inherits the active host's exact height directly.
        let turn = UUID()
        var ledger = TranscriptMeasurementLedger()
        ledger.setExact(123, for: active(turn).layoutKey)
        TranscriptRowSet.transferActiveHeightIfNeeded(from: [active(turn)], to: [settled(turn)], ledger: &ledger)
        #expect(ledger[settled(turn).layoutKey] == 123)
        #expect(!ledger.isStale(settled(turn).layoutKey))
    }

    @Test func doesNotTransferWhenActiveSettlesIntoMultipleRows() {
        let turn = UUID()
        let activeRow = active(turn)
        var ledger = TranscriptMeasurementLedger()
        ledger.setExact(123, for: activeRow.layoutKey)
        let slices = [
            Row(id: .planHeader(turn), content: .error(""), estimatedHeight: 10),
            Row(id: .plan(turn), content: .error(""), estimatedHeight: 10),
        ]

        TranscriptRowSet.transferActiveHeightIfNeeded(from: [activeRow], to: slices, ledger: &ledger)

        #expect(ledger[slices[0].layoutKey] == nil)
        #expect(ledger[slices[1].layoutKey] == nil)
    }

    @Test func doesNotTransferWhenReplacementAlreadyMeasuredOrActiveSurvives() {
        let turn = UUID()
        let activeRow = active(turn)
        let settledRow = settledResult(turn)
        var ledger = TranscriptMeasurementLedger()
        ledger.setExact(123, for: activeRow.layoutKey)
        ledger.setExact(50, for: settledRow.layoutKey)

        TranscriptRowSet.transferActiveHeightIfNeeded(from: [activeRow], to: [settledRow], ledger: &ledger)
        #expect(ledger[settledRow.layoutKey] == 50)
        #expect(!ledger.isStale(settledRow.layoutKey))

        var untouched = TranscriptMeasurementLedger()
        untouched.setExact(123, for: activeRow.layoutKey)
        TranscriptRowSet.transferActiveHeightIfNeeded(
            from: [activeRow], to: [activeRow, settledResult(UUID())], ledger: &untouched
        )
        #expect(untouched.heightsByKey.count == 1)
    }
}
