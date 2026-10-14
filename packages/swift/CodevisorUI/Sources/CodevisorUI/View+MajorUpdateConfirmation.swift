import CodevisorCore
import SwiftUI

public extension View {
  func majorUpdateConfirmation(
    _ component: Binding<UpdateComponent?>,
    perform: @escaping (UpdateComponent) -> Void
  ) -> some View {
    alert(
      component.wrappedValue.map { "Update \($0.title) to \($0.latestVersion ?? "the new version")?" } ?? "",
      isPresented: Binding(
        get: { component.wrappedValue != nil },
        set: { if !$0 { component.wrappedValue = nil } }
      ),
      presenting: component.wrappedValue
    ) { item in
      Button("Update") { perform(item) }
      Button("Cancel", role: .cancel) {}
    } message: { item in
      Text(item.notes ?? "")
    }
  }
}
