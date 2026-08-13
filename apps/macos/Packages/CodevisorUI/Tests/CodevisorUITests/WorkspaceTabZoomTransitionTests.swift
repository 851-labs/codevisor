import CoreGraphics
import Testing
@testable import CodevisorUI

@Suite("Workspace tab zoom transition")
struct WorkspaceTabZoomTransitionTests {
    private let viewport = CGRect(x: 0, y: 0, width: 402, height: 874)
    private let card = CGRect(x: 16, y: 132, width: 178, height: 232)
    private let canvas = CGSize(width: 402, height: 874)

    @Test("Opening the grid collapses the pane into its exact card")
    func paneToGrid() throws {
        let plan = try #require(WorkspaceTabZoomTransitionContract.plan(
            direction: .paneToGrid,
            viewportFrame: viewport,
            cardFrame: card,
            canvasSize: canvas
        ))

        #expect(plan.source.maskFrame == viewport)
        #expect(plan.destination.maskFrame == card)
        #expect(plan.source.cornerRadius == 0)
        #expect(plan.destination.cornerRadius == 16)
        #expect(plan.duration == 0.28)
        #expect(WorkspaceTabZoomTransitionContract.dampingRatio == 0.93)
        #expect(WorkspaceTabZoomTransitionContract.handoffDelayFactor == 0.84)
        #expect(WorkspaceTabZoomTransitionContract.uncachedHandoffDelayFactor == 1)
    }

    @Test("The page canvas uses one uniform scale at both endpoints")
    func fixedCanvasGeometry() throws {
        let plan = try #require(WorkspaceTabZoomTransitionContract.plan(
            direction: .paneToGrid,
            viewportFrame: viewport,
            cardFrame: card,
            canvasSize: canvas
        ))

        let fullFrame = plan.source.renderedCanvasFrame(canvasSize: canvas)
        let cardFrame = plan.destination.renderedCanvasFrame(canvasSize: canvas)

        #expect(plan.canvasSize == canvas)
        #expect(plan.source.canvasScale == 1)
        #expect(fullFrame == viewport)
        #expect(cardFrame.minY == card.minY)
        #expect(cardFrame.midX == card.midX)
        #expect(cardFrame.width >= card.width)
        #expect(cardFrame.height >= card.height)
        #expect(
            cardFrame.width / canvas.width
                == cardFrame.height / canvas.height
        )
    }

    @Test("Opening a pane is the exact reverse geometry")
    func gridToPane() throws {
        let collapse = try #require(WorkspaceTabZoomTransitionContract.plan(
            direction: .paneToGrid,
            viewportFrame: viewport,
            cardFrame: card,
            canvasSize: canvas
        ))
        let expand = try #require(WorkspaceTabZoomTransitionContract.plan(
            direction: .gridToPane,
            viewportFrame: viewport,
            cardFrame: card,
            canvasSize: canvas
        ))

        #expect(expand.source == collapse.destination)
        #expect(expand.destination == collapse.source)
        #expect(expand.canvasSize == collapse.canvasSize)
    }

    @Test("A newly inserted tab expands from its measured grid card")
    func newTabGridToPane() throws {
        let plan = try #require(WorkspaceTabZoomTransitionContract.plan(
            direction: .gridToPane,
            viewportFrame: viewport,
            cardFrame: card,
            canvasSize: viewport.size
        ))

        #expect(plan.source.maskFrame == card)
        #expect(plan.source.cornerRadius == 16)
        #expect(plan.destination.maskFrame == viewport)
        #expect(plan.destination.cornerRadius == 0)
        #expect(plan.destination.renderedCanvasFrame(canvasSize: viewport.size) == viewport)
    }

    @Test("An uncached placeholder begins centered in its grid card")
    func uncachedPlaceholderAlignment() throws {
        let y = try #require(
            WorkspaceTabZoomTransitionContract.uncachedPlaceholderSymbolCenterY(
                canvasSize: canvas,
                cardSize: card.size
            )
        )
        let scale = max(card.width / canvas.width, card.height / canvas.height)

        #expect(y * scale == card.height / 2)
        #expect(WorkspaceTabZoomTransitionContract.uncachedPlaceholderSymbolCenterY(
            canvasSize: .zero,
            cardSize: card.size
        ) == nil)
    }

    @Test("Reduced motion and invalid measurements skip the pixel overlay")
    func rejectsInapplicableMotion() {
        #expect(WorkspaceTabZoomTransitionContract.plan(
            direction: .paneToGrid,
            viewportFrame: viewport,
            cardFrame: card,
            canvasSize: canvas,
            reduceMotion: true
        ) == nil)
        #expect(WorkspaceTabZoomTransitionContract.plan(
            direction: .paneToGrid,
            viewportFrame: .zero,
            cardFrame: card,
            canvasSize: canvas
        ) == nil)
        #expect(WorkspaceTabZoomTransitionContract.plan(
            direction: .gridToPane,
            viewportFrame: viewport,
            cardFrame: CGRect(x: 500, y: 0, width: 100, height: 100),
            canvasSize: canvas
        ) == nil)
        #expect(WorkspaceTabZoomTransitionContract.plan(
            direction: .gridToPane,
            viewportFrame: viewport,
            cardFrame: card,
            canvasSize: .zero
        ) == nil)
    }
}
