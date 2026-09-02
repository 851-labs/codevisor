import AppKit
import CoreGraphics
import Testing
@testable import CodevisorCore
@testable import CodevisorCoreMac

extension ComputerUseBridgeTests {
    @Test("Keeps the cursor artwork pointed up-left with its hotspot at the tip")
    @MainActor
    func cursorArtworkAndHotspot() {
        let artwork = computerUsePointerArtwork(size: ComputerUseCursorMetrics.pointerSize)
        let path = computerUsePointerPath(
            tip: ComputerUseCursorMetrics.tipAnchor,
            size: ComputerUseCursorMetrics.pointerSize
        )

        #expect(artwork.path.elementCount >= 16)
        #expect(artwork.tip.x < artwork.path.bounds.midX)
        #expect(artwork.tip.y > artwork.path.bounds.midY)
        #expect(path.bounds.midX > ComputerUseCursorMetrics.tipAnchor.x)
        #expect(path.bounds.midY < ComputerUseCursorMetrics.tipAnchor.y)
    }

    @Test("Keeps the visual hotspot exact when the glow extends past a screen edge")
    func cursorHotspotDoesNotClampAtScreenEdges() {
        let clickPoint = CGPoint(x: 738, y: 1_680)
        let panelOrigin = computerUseCursorPanelOrigin(for: clickPoint)
        let renderedTip = CGPoint(
            x: panelOrigin.x + ComputerUseCursorMetrics.tipAnchor.x,
            y: panelOrigin.y + ComputerUseCursorMetrics.tipAnchor.y
        )

        #expect(renderedTip == clickPoint)
        #expect(
            panelOrigin.y + ComputerUseCursorMetrics.windowSize.height > 1_706,
            "The transparent glow should extend offscreen instead of displacing the hotspot"
        )
    }

    @Test("Allows the cursor panel itself to extend beyond the visible screen")
    @MainActor
    func cursorPanelDoesNotApplyAppKitClamping() {
        let requestedFrame = CGRect(x: 677.65, y: 1_609.7, width: 126, height: 126)
        let panel = ComputerUseCursorPanel(
            contentRect: CGRect(origin: .zero, size: ComputerUseCursorMetrics.windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        #expect(panel.constrainFrameRect(requestedFrame, to: NSScreen.main) == requestedFrame)
    }

    @Test("Keeps the hotspot fixed during the center-pivot idle wiggle")
    func cursorIdleRotationPreservesHotspot() {
        let tip = ComputerUseCursorMetrics.tipAnchor
        let pivot = CGPoint(x: tip.x + 7, y: tip.y - 8)
        let transform = computerUseTipPreservingRotation(
            tip: tip,
            pivot: pivot,
            angle: 0.09
        )
        let transformedTip = tip.applying(transform)

        #expect(abs(transformedTip.x - tip.x) < 0.000_001)
        #expect(abs(transformedTip.y - tip.y) < 0.000_001)
        #expect(pivot.applying(transform) != pivot)
    }

    @Test("Shows the cursor only while its target window is on a visible Space")
    func cursorTargetSpaceVisibility() {
        let visibleWindowID: CGWindowID = 42
        let visiblePID: pid_t = 314
        let visibleWindows: [[String: Any]] = [
            [
                kCGWindowNumber as String: NSNumber(value: visibleWindowID),
                kCGWindowOwnerPID as String: NSNumber(value: visiblePID),
            ]
        ]

        #expect(
            computerUseTargetIsOnVisibleSpace(
                targetWindowID: visibleWindowID,
                pid: visiblePID,
                windowInfo: visibleWindows
            ))
        #expect(
            !computerUseTargetIsOnVisibleSpace(
                targetWindowID: visibleWindowID + 1,
                pid: visiblePID,
                windowInfo: visibleWindows
            ))
        #expect(
            computerUseTargetIsOnVisibleSpace(
                targetWindowID: nil,
                pid: visiblePID,
                windowInfo: visibleWindows
            ))
        #expect(
            !computerUseTargetIsOnVisibleSpace(
                targetWindowID: nil,
                pid: visiblePID + 1,
                windowInfo: visibleWindows
            ))
    }

    @Test("Shows the cursor whenever the controlled window is on the visible Space")
    func cursorVisibilityTracksTheTargetWindow() {
        let targetWindowID: CGWindowID = 42
        let targetPID: pid_t = 314
        let visibleWindows: [[String: Any]] = [
            [
                kCGWindowNumber as String: NSNumber(value: targetWindowID),
                kCGWindowOwnerPID as String: NSNumber(value: targetPID),
            ]
        ]

        #expect(
            computerUseCursorShouldBeVisible(
                targetWindowID: targetWindowID,
                targetPID: targetPID,
                windowInfo: visibleWindows
            ))
        // A different app may be ahead in the WindowServer list. Visibility
        // remains attached to the target; panel ordering handles occlusion.
        let withUnrelatedFrontWindow: [[String: Any]] =
            [
                [
                    kCGWindowNumber as String: NSNumber(value: targetWindowID + 1),
                    kCGWindowOwnerPID as String: NSNumber(value: targetPID + 1),
                ]
            ] + visibleWindows
        #expect(
            computerUseCursorShouldBeVisible(
                targetWindowID: targetWindowID,
                targetPID: targetPID,
                windowInfo: withUnrelatedFrontWindow
            ))
        #expect(
            !computerUseCursorShouldBeVisible(
                targetWindowID: targetWindowID,
                targetPID: targetPID,
                windowInfo: []
            ))
        #expect(
            computerUseWindowIsOnVisibleSpace(
                targetWindowID,
                windowInfo: visibleWindows
            ))
    }

    @Test("Promotes background events to foreground for a window on another Space")
    func crossSpaceDeliveryMode() {
        #expect(
            computerUseResolvedDeliveryMode(
                requested: "background",
                targetIsOnVisibleSpace: false
            ) == "foreground")
        #expect(
            computerUseResolvedDeliveryMode(
                requested: "background",
                targetIsOnVisibleSpace: true
            ) == "background")
        #expect(
            computerUseResolvedDeliveryMode(
                requested: "foreground",
                targetIsOnVisibleSpace: false
            ) == "foreground")
        #expect(
            computerUseResolvedDeliveryMode(
                requested: "invalid",
                targetIsOnVisibleSpace: true
            ) == nil)
    }

    @Test("Uses the same smooth cursor geometry at overlay and menu-bar scales")
    @MainActor
    func cursorGeometryScalesCleanly() {
        let overlayPath = computerUsePointerPath(
            in: CGRect(origin: .zero, size: ComputerUseCursorMetrics.pointerSize)
        )
        let statusPath = computerUsePointerPath(
            in: CGRect(origin: .zero, size: ComputerUseStatusMetrics.cursorSize),
            rotation: ComputerUseStatusMetrics.cursorArtworkRotation
        )

        #expect(overlayPath.elementCount == statusPath.elementCount)
        #expect(overlayPath.elementCount >= 16)
        #expect(ComputerUseStatusMetrics.cursorSize.height < ComputerUseStatusMetrics.iconSize)
        #expect(
            ComputerUseStatusMetrics.cursorArtworkRotation
                > ComputerUseCursorMetrics.artworkRotation
        )
    }

    @Test("Rasterizes the vector cursor cleanly at 1x and Retina backing scales")
    @MainActor
    func cursorBackingScales() throws {
        var paintedByteCounts: [Int] = []
        for scale in [1, 2] {
            let representation = try #require(
                NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: 20 * scale,
                    pixelsHigh: 22 * scale,
                    bitsPerSample: 8,
                    samplesPerPixel: 4,
                    hasAlpha: true,
                    isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bitmapFormat: [],
                    bytesPerRow: 0,
                    bitsPerPixel: 0
                ))
            let graphicsContext = try #require(NSGraphicsContext(bitmapImageRep: representation))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphicsContext
            NSColor.white.setFill()
            computerUsePointerPath(
                in: CGRect(
                    x: 2 * scale,
                    y: 2 * scale,
                    width: 12 * scale,
                    height: 14 * scale
                )
            ).fill()
            NSGraphicsContext.restoreGraphicsState()

            let bitmapData = try #require(representation.bitmapData)
            let bytes = UnsafeBufferPointer(
                start: bitmapData,
                count: representation.bytesPerRow * representation.pixelsHigh
            )
            paintedByteCounts.append(
                bytes.reduce(into: 0) { count, byte in
                    if byte != 0 { count += 1 }
                })
        }

        #expect(paintedByteCounts[0] > 0)
        #expect(paintedByteCounts[1] > paintedByteCounts[0] * 3)
    }

    @Test("Assigns each session a stable cursor color and avoids live collisions")
    @MainActor
    func cursorColorAssignment() {
        let paletteCount = ComputerUseCursorPalette.colors.count
        let preferred = computerUseCursorColorIndex(
            sessionID: "session-a",
            takenIndices: [],
            paletteCount: paletteCount
        )

        // Deterministic: the same session always prefers the same color.
        #expect(
            preferred
                == computerUseCursorColorIndex(
                    sessionID: "session-a",
                    takenIndices: [],
                    paletteCount: paletteCount
                ))
        #expect((0..<paletteCount).contains(preferred))

        // A concurrent session holding that color pushes this one elsewhere.
        let probed = computerUseCursorColorIndex(
            sessionID: "session-a",
            takenIndices: [preferred],
            paletteCount: paletteCount
        )
        #expect(probed != preferred)
        #expect((0..<paletteCount).contains(probed))

        // With every color in use, stability wins over uniqueness.
        #expect(
            computerUseCursorColorIndex(
                sessionID: "session-a",
                takenIndices: Set(0..<paletteCount),
                paletteCount: paletteCount
            ) == preferred)
    }

    @Test("Releases a session's share only once it has actually gone quiet")
    func idleSessionRelease() {
        let now = Date()
        let lastActivity = [
            "working": now.addingTimeInterval(-2),
            "thinking": now.addingTimeInterval(-computerUseIdleReleaseAfter + 5),
            "finished": now.addingTimeInterval(-computerUseIdleReleaseAfter - 1),
            "abandoned": now.addingTimeInterval(-3_600),
        ]
        let idle = computerUseIdleSessions(lastActivity: lastActivity, now: now)

        // A gap between tool calls inside a turn must not drop the share, or
        // the sharing indicator would blink through normal work.
        #expect(idle == ["abandoned", "finished"])
        // The threshold is long enough to span a model's thinking pause.
        #expect(computerUseIdleReleaseAfter >= 30)
    }

    @Test("Centers menu-bar content with one chip and one matching hit width")
    func statusItemGeometry() {
        let width = ComputerUseStatusMetrics.width(appCount: 1)
        let bounds = CGRect(x: 0, y: 0, width: width, height: ComputerUseStatusMetrics.chipHeight)
        let iconFrame = ComputerUseStatusMetrics.iconFrame(index: 0, in: bounds)
        let cursorFrame = ComputerUseStatusMetrics.cursorFrame(appCount: 1, in: bounds)

        #expect(width == 50)
        #expect(ComputerUseStatusMetrics.chipHeight == 24)
        #expect(iconFrame.minY == iconFrame.maxY.distance(to: bounds.maxY))
        #expect(cursorFrame.minY == cursorFrame.maxY.distance(to: bounds.maxY))
        #expect(cursorFrame.maxX + ComputerUseStatusMetrics.horizontalPadding <= bounds.maxX)
    }
}
