import Foundation
import Testing
import UIKit

@testable import TranscriptSurface

@Suite("First-send background appearance")
@MainActor
struct ChatSurfaceBackgroundTests {
  @Test("The expanded sheet keeps the destination color until handoff", arguments: [0.0, 28.0], [0.0, 0.35])
  func destinationAppearanceSurvivesExpansion(fadeHeight: Double, duration: Double) throws {
    let source = background(fadeHeight: fadeHeight, level: .elevated)
    let destination = background(fadeHeight: fadeHeight, level: .base)
    let sheetAppearance = try render(source)
    let destinationAppearance = try render(destination)
    #expect(sheetAppearance != destinationAppearance)

    source.prepareForPromotion()
    source.animatePromotion(to: destination.traitCollection, duration: duration)
    #expect(try render(source) == destinationAppearance)

    // The expansion ends before the workspace mounts and dismisses the
    // sheet. Its elevated traits still apply throughout that interval.
    source.finishPromotionAnimation()
    #expect(source.traitCollection.userInterfaceLevel == .elevated)
    #expect(try render(source) == destinationAppearance)

    // Late trait notifications from the live sheet must not restore gray.
    source.traitOverrides.accessibilityContrast = .high
    source.updateTraitsIfNeeded()
    #expect(try render(source) == destinationAppearance)
  }

  private func background(fadeHeight: Double, level: UIUserInterfaceLevel) -> ChatSurfaceBackgroundView {
    let view = ChatSurfaceBackgroundView(fadeHeight: fadeHeight)
    view.frame = CGRect(x: 0, y: 0, width: 40, height: 80)
    view.traitOverrides.userInterfaceStyle = .dark
    view.traitOverrides.userInterfaceLevel = level
    view.updateTraitsIfNeeded()
    view.setNeedsLayout()
    view.layoutIfNeeded()
    return view
  }

  private func render(_ view: UIView) throws -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.preferredRange = .standard
    let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
      view.layer.render(in: context.cgContext)
    }
    return try #require(image.pngData())
  }
}
