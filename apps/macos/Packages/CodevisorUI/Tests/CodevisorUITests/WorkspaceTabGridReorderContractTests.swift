import CoreGraphics
import Testing
@testable import CodevisorUI

@Suite("Workspace tab grid reorder contract")
struct WorkspaceTabGridReorderContractTests {
    private let slots = [
        WorkspaceTabGridSlot(
            index: 0,
            frame: CGRect(x: 16, y: 100, width: 178, height: 205)
        ),
        WorkspaceTabGridSlot(
            index: 1,
            frame: CGRect(x: 208, y: 100, width: 178, height: 205)
        ),
        WorkspaceTabGridSlot(
            index: 2,
            frame: CGRect(x: 16, y: 341, width: 178, height: 205)
        ),
        WorkspaceTabGridSlot(
            index: 3,
            frame: CGRect(x: 208, y: 341, width: 178, height: 205)
        )
    ]

    @Test("Crossing only the midpoint does not reorder")
    func midpointDeadBand() {
        let left = slots[0].frame.midX
        let right = slots[1].frame.midX
        let midpoint = (left + right) / 2

        #expect(WorkspaceTabGridReorderContract.targetIndex(
            currentIndex: 0,
            point: CGPoint(x: midpoint, y: slots[0].frame.midY),
            slots: slots
        ) == nil)
        #expect(WorkspaceTabGridReorderContract.targetIndex(
            currentIndex: 0,
            point: CGPoint(
                x: left + (right - left) * 0.57,
                y: slots[0].frame.midY
            ),
            slots: slots
        ) == nil)
    }

    @Test("A deliberate crossing commits to the neighboring slot")
    func commitsBeyondThreshold() {
        let left = slots[0].frame.midX
        let right = slots[1].frame.midX

        #expect(WorkspaceTabGridReorderContract.targetIndex(
            currentIndex: 0,
            point: CGPoint(
                x: left + (right - left) * 0.6,
                y: slots[0].frame.midY
            ),
            slots: slots
        ) == 1)
    }

    @Test("The inverse threshold prevents immediate reorder bounce")
    func hysteresisAfterCommit() {
        let left = slots[0].frame.midX
        let right = slots[1].frame.midX
        let committedPoint = CGPoint(
            x: left + (right - left) * 0.6,
            y: slots[0].frame.midY
        )

        #expect(WorkspaceTabGridReorderContract.targetIndex(
            currentIndex: 1,
            point: committedPoint,
            slots: slots
        ) == nil)
        #expect(WorkspaceTabGridReorderContract.targetIndex(
            currentIndex: 1,
            point: CGPoint(
                x: right + (left - right) * 0.6,
                y: slots[0].frame.midY
            ),
            slots: slots
        ) == 0)
    }

    @Test("Vertical and diagonal motion resolve against fixed slots")
    func twoDimensionalGrid() {
        #expect(WorkspaceTabGridReorderContract.targetIndex(
            currentIndex: 0,
            point: CGPoint(
                x: slots[2].frame.midX,
                y: slots[0].frame.midY
                    + (slots[2].frame.midY - slots[0].frame.midY) * 0.6
            ),
            slots: slots
        ) == 2)

        #expect(WorkspaceTabGridReorderContract.targetIndex(
            currentIndex: 0,
            point: slots[3].frame.center,
            slots: slots
        ) == 3)
    }

    @Test("Leaving the grid does not mutate the last valid order")
    func rejectsFarOutsidePoint() {
        #expect(WorkspaceTabGridReorderContract.targetIndex(
            currentIndex: 0,
            point: CGPoint(x: -500, y: -500),
            slots: slots
        ) == nil)
    }

    @Test("Missing or invalid current measurements are inert")
    func rejectsInvalidMeasurements() {
        #expect(WorkspaceTabGridReorderContract.targetIndex(
            currentIndex: 99,
            point: .zero,
            slots: slots
        ) == nil)
        #expect(WorkspaceTabGridReorderContract.targetIndex(
            currentIndex: 0,
            point: .zero,
            slots: [
                WorkspaceTabGridSlot(index: 0, frame: .null)
            ]
        ) == nil)
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
