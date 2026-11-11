import CodevisorUI
import SwiftUI

struct ComposerSlimBar<Field: View>: View {
  private static var fieldShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: ComposerSlimAttachMenu.diameter / 2)
  }

  private static var horizontalPadding: CGFloat { 14 }
  private static var verticalPadding: CGFloat { 4 }

  let field: Field
  let hasChips: Bool
  let glassNamespace: Namespace.ID?
  let onAttachPhotos: () -> Void
  let onAttachFiles: () -> Void

  var body: some View {
    HStack(alignment: .bottom, spacing: ComposerSlimLayout.fieldSpacing) {
      ComposerSlimAttachMenu(onPhotos: onAttachPhotos, onFiles: onAttachFiles)
      field
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.top, hasChips ? Self.horizontalPadding : Self.verticalPadding)
        .padding(.bottom, Self.verticalPadding)
        .composerGlassSurface(shape: Self.fieldShape, id: .composer, in: glassNamespace)
    }
  }
}
