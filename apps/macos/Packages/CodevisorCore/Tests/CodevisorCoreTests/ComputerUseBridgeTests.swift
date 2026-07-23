import AppKit
import CoreGraphics
import Testing
@testable import CodevisorCore

@Suite("Computer Use coordinates")
struct ComputerUseBridgeTests {
    @Test("Matches installed apps by native Computer Use identifiers")
    func installedApplicationIdentifiers() {
        let calculator = ComputerUseApplicationIdentity(
            id: "com.apple.calculator",
            displayName: "Calculator",
            path: "/System/Applications/Calculator.app"
        )

        #expect(computerUseApplicationMatchScore(
            query: "Calculator",
            identity: calculator
        ) == 0)
        #expect(computerUseApplicationMatchScore(
            query: "com.apple.calculator",
            identity: calculator
        ) == 0)
        #expect(computerUseApplicationMatchScore(
            query: "/System/Applications/Calculator.app",
            identity: calculator
        ) == 0)
        #expect(computerUseApplicationMatchScore(
            query: "Calcul",
            identity: calculator
        ) == 1)
        #expect(computerUseApplicationMatchScore(
            query: "Notes",
            identity: calculator
        ) == nil)
    }

    @Test("Searches system, global, and user application directories")
    func installedApplicationRoots() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let roots = computerUseApplicationSearchRoots(homeDirectory: home).map(\.path)

        #expect(roots.contains("/Applications"))
        #expect(roots.contains("/System/Applications"))
        #expect(roots.contains("/System/Library/CoreServices/Applications"))
        #expect(roots.contains("/Users/example/Applications"))
    }

    @Test("Caps native sharing previews without changing their aspect ratio")
    func nativeSharingPreviewSize() {
        #expect(computerUseNativePreviewSize(
            windowFrame: CGRect(x: 10, y: 20, width: 1_200, height: 800),
            pointPixelScale: 2
        ) == CGSize(width: 960, height: 640))
        #expect(computerUseNativePreviewSize(
            windowFrame: CGRect(x: 10, y: 20, width: 300, height: 200),
            pointPixelScale: 2
        ) == CGSize(width: 600, height: 400))
        #expect(computerUseNativePreviewSize(
            windowFrame: .zero,
            pointPixelScale: 2
        ) == ComputerUseNativePreviewMetrics.fallbackSize)
    }

    @Test("Maps Retina screenshot pixels back to logical window points")
    func mapsRetinaScreenshotCoordinates() {
        let point = computerUseScreenshotPoint(
            x: 656,
            y: 422,
            screenshotPixelSize: CGSize(width: 1_312, height: 844),
            windowFrame: CGRect(x: 500, y: 77, width: 656, height: 422)
        )

        #expect(point == CGPoint(x: 828, y: 288))
    }

    @Test("Reports accessibility frames in screenshot pixels")
    func mapsAccessibilityFramesToScreenshotCoordinates() {
        let frame = computerUseScreenshotFrame(
            screenFrame: CGRect(x: 664, y: 161, width: 120, height: 44),
            screenshotPixelSize: CGSize(width: 1_312, height: 844),
            windowFrame: CGRect(x: 500, y: 77, width: 656, height: 422)
        )

        #expect(frame == CGRect(x: 328, y: 168, width: 240, height: 88))
    }

    @Test("Clamps stale or out-of-bounds screenshot coordinates to the target window")
    func clampsCoordinatesToWindow() {
        let frame = CGRect(x: 100, y: 200, width: 300, height: 150)

        #expect(computerUseScreenshotPoint(
            x: -200,
            y: 9_000,
            screenshotPixelSize: CGSize(width: 600, height: 300),
            windowFrame: frame
        ) == CGPoint(x: 100.5, y: 349.5))
    }

    @Test("Keeps semantic and pixel click addressing mutually exclusive")
    func distinguishesClickAddressing() {
        #expect(computerUseClickAddressing(
            snapshotID: "snapshot",
            elementID: "12",
            x: nil,
            y: nil
        ) == .semantic)
        #expect(computerUseClickAddressing(
            snapshotID: "snapshot",
            elementID: nil,
            x: 40,
            y: 80
        ) == .pixel)
        #expect(computerUseClickAddressing(
            snapshotID: "snapshot",
            elementID: "12",
            x: 40,
            y: 80
        ) == .ambiguous)
        #expect(computerUseClickAddressing(
            snapshotID: nil,
            elementID: nil,
            x: 40,
            y: nil
        ) == .invalid)
    }

    @Test("Recognizes Chromium-class app identities without classifying Safari")
    func identifiesChromiumTargets() {
        #expect(computerUseUsesChromiumInput(
            appName: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        ))
        #expect(computerUseUsesChromiumInput(
            appName: "Arc",
            bundleIdentifier: "company.thebrowser.Browser",
            executablePath: nil
        ))
        #expect(!computerUseUsesChromiumInput(
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            executablePath: "/Applications/Safari.app/Contents/MacOS/Safari"
        ))
    }

    @Test("Builds the Chromium primer and target click as one explicit sequence")
    func chromiumClickSequence() {
        let target = CGPoint(x: 840, y: 610)
        let local = CGPoint(x: 340, y: 533)
        let steps = computerUseChromiumClickPlan(
            point: target,
            windowPoint: local,
            count: 2
        )

        #expect(steps.count == 7)
        #expect(steps[0] == ComputerUseChromiumClickStep(
            kind: .move,
            point: target,
            windowPoint: local,
            phase: 2,
            clickState: 0,
            delayAfterMilliseconds: 15
        ))
        #expect(steps[1].point == CGPoint(x: -1, y: -1))
        #expect(steps[1].kind == .down)
        #expect(steps[2].kind == .up)
        #expect(steps[2].delayAfterMilliseconds == 100)
        #expect(steps[3].clickState == 1)
        #expect(steps[5].clickState == 2)
        #expect(steps[6].delayAfterMilliseconds == 0)
    }

    @Test("Matches native Computer Use modifier aliases")
    func modifierAliases() {
        #expect(computerUseModifierFlag(named: "super") == .maskCommand)
        #expect(computerUseModifierFlag(named: "meta") == .maskCommand)
        #expect(computerUseModifierFlag(named: "control") == .maskControl)
        #expect(computerUseModifierFlag(named: "alt") == .maskAlternate)
        #expect(computerUseModifierFlag(named: "shift") == .maskShift)
        #expect(computerUseModifierFlag(named: "hyper") == nil)
    }

    @Test("Matches native Computer Use mouse-button aliases")
    func mouseButtonAliases() {
        #expect(computerUseMouseButton(named: "left") == "left")
        #expect(computerUseMouseButton(named: "l") == "left")
        #expect(computerUseMouseButton(named: "right") == "right")
        #expect(computerUseMouseButton(named: "r") == "right")
        #expect(computerUseMouseButton(named: "middle") == "middle")
        #expect(computerUseMouseButton(named: "m") == "middle")
        #expect(computerUseMouseButton(named: "side") == nil)
    }

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
        let visibleWindows: [[String: Any]] = [[
            kCGWindowNumber as String: NSNumber(value: visibleWindowID),
            kCGWindowOwnerPID as String: NSNumber(value: visiblePID)
        ]]

        #expect(computerUseTargetIsOnVisibleSpace(
            targetWindowID: visibleWindowID,
            pid: visiblePID,
            windowInfo: visibleWindows
        ))
        #expect(!computerUseTargetIsOnVisibleSpace(
            targetWindowID: visibleWindowID + 1,
            pid: visiblePID,
            windowInfo: visibleWindows
        ))
        #expect(computerUseTargetIsOnVisibleSpace(
            targetWindowID: nil,
            pid: visiblePID,
            windowInfo: visibleWindows
        ))
        #expect(!computerUseTargetIsOnVisibleSpace(
            targetWindowID: nil,
            pid: visiblePID + 1,
            windowInfo: visibleWindows
        ))
    }

    @Test("Shows the cursor whenever the controlled window is on the visible Space")
    func cursorVisibilityTracksTheTargetWindow() {
        let targetWindowID: CGWindowID = 42
        let targetPID: pid_t = 314
        let visibleWindows: [[String: Any]] = [[
            kCGWindowNumber as String: NSNumber(value: targetWindowID),
            kCGWindowOwnerPID as String: NSNumber(value: targetPID)
        ]]

        #expect(computerUseCursorShouldBeVisible(
            targetWindowID: targetWindowID,
            targetPID: targetPID,
            windowInfo: visibleWindows
        ))
        // A different app may be ahead in the WindowServer list. Visibility
        // remains attached to the target; panel ordering handles occlusion.
        let withUnrelatedFrontWindow: [[String: Any]] = [[
            kCGWindowNumber as String: NSNumber(value: targetWindowID + 1),
            kCGWindowOwnerPID as String: NSNumber(value: targetPID + 1)
        ]] + visibleWindows
        #expect(computerUseCursorShouldBeVisible(
            targetWindowID: targetWindowID,
            targetPID: targetPID,
            windowInfo: withUnrelatedFrontWindow
        ))
        #expect(!computerUseCursorShouldBeVisible(
            targetWindowID: targetWindowID,
            targetPID: targetPID,
            windowInfo: []
        ))
        #expect(computerUseWindowIsOnVisibleSpace(
            targetWindowID,
            windowInfo: visibleWindows
        ))
    }

    @Test("Promotes background events to foreground for a window on another Space")
    func crossSpaceDeliveryMode() {
        #expect(computerUseResolvedDeliveryMode(
            requested: "background",
            targetIsOnVisibleSpace: false
        ) == "foreground")
        #expect(computerUseResolvedDeliveryMode(
            requested: "background",
            targetIsOnVisibleSpace: true
        ) == "background")
        #expect(computerUseResolvedDeliveryMode(
            requested: "foreground",
            targetIsOnVisibleSpace: false
        ) == "foreground")
        #expect(computerUseResolvedDeliveryMode(
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
            let representation = try #require(NSBitmapImageRep(
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
            paintedByteCounts.append(bytes.reduce(into: 0) { count, byte in
                if byte != 0 { count += 1 }
            })
        }

        #expect(paintedByteCounts[0] > 0)
        #expect(paintedByteCounts[1] > paintedByteCounts[0] * 3)
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
