import SwiftUI
import UIKit

/// Measures the rendered composer and picker slot in the sheet's coordinate
/// space. The promotion snapshot must use their layout, including attachments
/// and Dynamic Type, instead of guessing from the text editor's top edge.
struct ComposerPromotionRegion: UIViewRepresentable {
  enum Kind {
    case composer
    case runPickers
  }

  let kind: Kind

  func makeUIView(context _: Context) -> RegionView {
    let view = RegionView()
    view.kind = kind
    view.isUserInteractionEnabled = false
    view.accessibilityElementsHidden = true
    return view
  }

  func updateUIView(_ view: RegionView, context _: Context) {
    view.kind = kind
  }

  final class RegionView: UIView {
    var kind = Kind.composer
  }

  static func frame(of kind: Kind, in view: UIView) -> CGRect? {
    guard
      let region = view.firstDescendant(where: {
        ($0 as? RegionView)?.kind == kind
      }), !region.bounds.isEmpty
    else { return nil }
    return region.convert(region.bounds, to: view)
  }
}
