import AppKit
import CoreGraphics
import Testing
@testable import CodevisorCore
@testable import CodevisorCoreMac

@Suite("Computer Use coordinates")
struct ComputerUseBridgeTests {
  @Test("Matches installed apps by native Computer Use identifiers")
  func installedApplicationIdentifiers() {
    let calculator = ComputerUseApplicationIdentity(
      id: "com.apple.calculator",
      displayName: "Calculator",
      path: "/System/Applications/Calculator.app"
    )

    #expect(
      computerUseApplicationMatchScore(
        query: "Calculator",
        identity: calculator
      ) == 0)
    #expect(
      computerUseApplicationMatchScore(
        query: "com.apple.calculator",
        identity: calculator
      ) == 0)
    #expect(
      computerUseApplicationMatchScore(
        query: "/System/Applications/Calculator.app",
        identity: calculator
      ) == 0)
    #expect(
      computerUseApplicationMatchScore(
        query: "Calcul",
        identity: calculator
      ) == 1)
    #expect(
      computerUseApplicationMatchScore(
        query: "Notes",
        identity: calculator
      ) == nil)
  }

  @Test("Allows Codevisor while continuing to protect credential managers")
  func protectedApplicationIdentities() {
    #expect(
      !computerUseApplicationIsProtected(
        ComputerUseApplicationIdentity(
          id: "com.851labs.Codevisor.Development",
          displayName: "Codevisor Dev",
          path: "/Applications/Codevisor Dev.app"
        )))
    #expect(
      computerUseApplicationIsProtected(
        ComputerUseApplicationIdentity(
          id: "com.1password.1password",
          displayName: "1Password",
          path: "/Applications/1Password.app"
        )))
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
    #expect(
      computerUseNativePreviewSize(
        windowFrame: CGRect(x: 10, y: 20, width: 1_200, height: 800),
        pointPixelScale: 2
      ) == CGSize(width: 960, height: 640))
    #expect(
      computerUseNativePreviewSize(
        windowFrame: CGRect(x: 10, y: 20, width: 300, height: 200),
        pointPixelScale: 2
      ) == CGSize(width: 600, height: 400))
    #expect(
      computerUseNativePreviewSize(
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

  @Test("Keeps semantic and pixel click addressing mutually exclusive")
  func distinguishesClickAddressing() {
    #expect(
      computerUseClickAddressing(
        snapshotID: "snapshot",
        elementID: "12",
        x: nil,
        y: nil
      ) == .semantic)
    #expect(
      computerUseClickAddressing(
        snapshotID: "snapshot",
        elementID: nil,
        x: 40,
        y: 80
      ) == .pixel)
    #expect(
      computerUseClickAddressing(
        snapshotID: "snapshot",
        elementID: "12",
        x: 40,
        y: 80
      ) == .ambiguous)
    #expect(
      computerUseClickAddressing(
        snapshotID: nil,
        elementID: nil,
        x: 40,
        y: nil
      ) == .invalid)
  }

  @Test("Recognizes Chromium-class app identities without classifying Safari")
  func identifiesChromiumTargets() {
    #expect(
      computerUseUsesChromiumInput(
        appName: "Google Chrome",
        bundleIdentifier: "com.google.Chrome",
        executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
      ))
    #expect(
      computerUseUsesChromiumInput(
        appName: "Arc",
        bundleIdentifier: "company.thebrowser.Browser",
        executablePath: nil
      ))
    #expect(
      !computerUseUsesChromiumInput(
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
    #expect(
      steps[0]
        == ComputerUseChromiumClickStep(
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

  @Test("Maps clicks through a snapshot only when it captured the target window")
  func snapshotWindowIdentity() {
    #expect(computerUseSnapshotMatchesWindow(snapshotWindowID: 42, targetWindowID: 42))
    #expect(!computerUseSnapshotMatchesWindow(snapshotWindowID: 42, targetWindowID: 43))
    // Unknown window identity must not authorize a coordinate mapping.
    #expect(!computerUseSnapshotMatchesWindow(snapshotWindowID: nil, targetWindowID: 42))
    #expect(!computerUseSnapshotMatchesWindow(snapshotWindowID: 42, targetWindowID: nil))
    #expect(!computerUseSnapshotMatchesWindow(snapshotWindowID: nil, targetWindowID: nil))
  }

  @Test("Derives Retina pixel sizes so snapshotless clicks never assume 1x")
  func derivedScreenshotPixelSize() {
    let frame = CGRect(x: 500, y: 77, width: 656, height: 422)

    #expect(
      computerUseDerivedScreenshotPixelSize(
        windowFrame: frame,
        pointPixelScale: 2
      ) == CGSize(width: 1_312, height: 844))
    #expect(
      computerUseDerivedScreenshotPixelSize(
        windowFrame: frame,
        pointPixelScale: 0.5
      ) == CGSize(width: 656, height: 422))

    // The derived size must round-trip through the shared conversion the
    // same way a real capture at that scale would.
    let point = computerUseScreenshotPoint(
      x: 656,
      y: 422,
      screenshotPixelSize: computerUseDerivedScreenshotPixelSize(
        windowFrame: frame,
        pointPixelScale: 2
      ),
      windowFrame: frame
    )
    #expect(point == CGPoint(x: 828, y: 288))
  }

  @Test("Mirrors an upside-down frame back onto the control it names")
  func mirrorsFlippedFrames() {
    // Chess's window, and the pawn it claims sits near the top while the
    // system reports that position belongs to the piece opposite it.
    let window = CGRect(x: 2_540, y: 30, width: 1_300, height: 1_007)
    let reported = CGRect(x: 955, y: 317.5, width: 77, height: 74.86)
    let corrected = computerUseMirroredFrame(reported, in: window)

    #expect(corrected.minX == reported.minX)
    #expect(corrected.width == reported.width)
    #expect(corrected.height == reported.height)
    // A centre reflects about the window's own centre line.
    #expect(abs(corrected.midY - (window.minY + window.maxY - reported.midY)) < 0.001)
    // Which moves this control out of the half it was wrongly reported in:
    // measured against the live app, its real centre is y ≈ 712, not 355.
    #expect(reported.midY < window.midY)
    #expect(corrected.midY > window.midY)
    #expect(abs(corrected.midY - 712.07) < 0.5)
    // Mirroring twice is the identity, so a correct frame stays correct.
    let round = computerUseMirroredFrame(corrected, in: window)
    #expect(abs(round.minY - reported.minY) < 0.001)
  }

  @Test("Only corrects orientation when the evidence is decisive")
  func flippedFrameVerdict() {
    // Chess: every sample resolved to its mirror.
    #expect(computerUseFramesAreFlipped(directHits: 0, mirroredHits: 14, samples: 14))
    // A healthy app resolves where it says it is.
    #expect(!computerUseFramesAreFlipped(directHits: 8, mirroredHits: 0, samples: 8))
    // Web-view apps resolve to neither; correcting them would invent
    // coordinates, so ambiguity must mean "leave it alone".
    #expect(!computerUseFramesAreFlipped(directHits: 0, mirroredHits: 0, samples: 6))
    // Nor is a thin majority enough.
    #expect(!computerUseFramesAreFlipped(directHits: 3, mirroredHits: 4, samples: 10))
    // Too few samples to conclude anything.
    #expect(!computerUseFramesAreFlipped(directHits: 0, mirroredHits: 2, samples: 2))
  }
}
