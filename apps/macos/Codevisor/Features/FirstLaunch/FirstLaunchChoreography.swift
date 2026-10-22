import CodevisorCore
import SwiftUI

struct FirstLaunchChoreography {
  let stage: FirstLaunchStage
  let frames: FirstLaunchFrames

  private var style: FirstLaunchDismissStyle { stage.style }
  private var isLeaving: Bool { stage.isLeaving }
  private var targets: [FirstLaunchLandingTarget: CGRect] { stage.targets }

  static let cardCornerRadius: CGFloat = 22

  func icon() -> FirstLaunchFlight {
    guard isLeaving else { return .rest }
    guard style == .iconZoom else { return .fade }
    return FirstLaunchFlight(scale: zoomScale, opacity: 0)
  }

  func chrome() -> FirstLaunchFlight {
    isLeaving ? .fade : .rest
  }

  func card() -> FirstLaunchFlight {
    guard isLeaving else { return .rest }
    switch style {
    case .flyIntoComposer: return .toward(composerInsertionPoint, from: frames.card, scale: 0.06)
    case .crossfade, .iconZoom: return .fade
    case .rowsIntoChips, .glassMorph: return .rest
    }
  }

  func row(_ step: FirstLaunchStep) -> FirstLaunchFlight {
    guard isLeaving else { return .rest }
    switch (style, step) {
    case (.rowsIntoChips, .harnesses): return .toward(targets[.modelChip], from: frames.rows[step], scale: 0.4)
    case (.rowsIntoChips, .projects): return .toward(targets[.projectChip], from: frames.rows[step], scale: 0.4)
    case (.rowsIntoChips, _), (.glassMorph, _): return .fade
    default: return .rest
    }
  }

  func glass() -> FirstLaunchGlassShape {
    let rest = FirstLaunchGlassShape(size: frames.card?.size, cornerRadius: Self.cardCornerRadius)
    guard isLeaving else { return rest }
    switch style {
    case .rowsIntoChips:
      return FirstLaunchGlassShape(size: rest.size, cornerRadius: Self.cardCornerRadius, scale: 0.92, opacity: 0)
    case .glassMorph: return morphedGlass() ?? rest
    case .crossfade, .flyIntoComposer, .iconZoom: return rest
    }
  }

  private var composerInsertionPoint: CGRect? {
    guard let composer = targets[.composer] else { return nil }
    return CGRect(
      x: composer.minX + Self.insertionInset.width, y: composer.minY + Self.insertionInset.height, width: 0, height: 0)
  }

  private static let insertionInset = CGSize(width: 36, height: 22)

  private func morphedGlass() -> FirstLaunchGlassShape? {
    guard let composer = targets[.composer], let card = frames.card else { return nil }
    let offset = CGSize(width: composer.midX - card.midX, height: composer.midY - card.midY)
    return FirstLaunchGlassShape(size: composer.size, cornerRadius: stage.composerCornerRadius, offset: offset)
  }

  private var zoomScale: CGFloat {
    let iconWidth = max(1, frames.icon?.width ?? 72)
    return max(stage.windowSize.width, stage.windowSize.height) / iconWidth * 1.4
  }
}
