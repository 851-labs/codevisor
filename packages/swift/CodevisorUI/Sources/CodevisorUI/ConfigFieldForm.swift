import CodevisorCore
import SwiftUI

public struct ConfigFieldForm: View {
  @Binding var draft: ConfigFieldDraft

  public init(draft: Binding<ConfigFieldDraft>) {
    _draft = draft
  }

  public var body: some View {
    ForEach(draft.visibleFields) { field in
      if draft.showsGeneratedValue(field) {
        ConfigFieldGeneratedValue(field: field, value: draft.values[field.key]?.text ?? "")
      } else {
        ConfigFieldRow(
          field: field,
          value: $draft.values[field.key],
          keepsSavedSecret: draft.keepsSavedSecret(field)
        )
      }
    }
  }
}
