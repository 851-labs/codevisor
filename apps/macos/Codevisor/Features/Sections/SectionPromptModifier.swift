import CodevisorCore
import CodevisorUI
import SwiftUI

struct SectionPromptModifier: ViewModifier {
  @Binding var prompt: SectionPrompt?
  let store: CustomSectionStore
  @State private var name = ""

  func body(content: Content) -> some View {
    content
      .alert(
        prompt?.title ?? "",
        isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } }),
        presenting: prompt
      ) { prompt in
        TextField("Name", text: $name)
        Button(prompt.confirmTitle) { confirm(prompt) }
        Button("Cancel", role: .cancel) {}
      }
      .focusesAlertTextField(when: prompt != nil)
      .onChange(of: prompt?.id) { name = prompt?.initialName ?? "" }
  }

  private func confirm(_ prompt: SectionPrompt) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    switch prompt {
    case let .create(moving):
      let section = store.create(name: trimmed)
      if let moving { store.move(moving, to: section.id) }
    case let .rename(section):
      store.rename(section.id, to: trimmed)
    }
  }
}
