import CodevisorUI
import SwiftUI

struct ComposerSlimBar<Field: View>: View {
  private static var fieldShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: ComposerSlimAttachMenu.diameter / 2)
  }

  let field: Field
  let glassNamespace: Namespace.ID?
  let onAttachPhotos: () -> Void
  let onAttachFiles: () -> Void

  var body: some View {
    HStack(alignment: .bottom, spacing: 10) {
      ComposerSlimAttachMenu(onPhotos: onAttachPhotos, onFiles: onAttachFiles)
      field
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .composerGlassSurface(shape: Self.fieldShape, id: .composer, in: glassNamespace)
    }
  }
}
