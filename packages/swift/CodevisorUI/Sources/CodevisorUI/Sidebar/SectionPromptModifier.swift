import CodevisorCore
import SwiftUI

public struct SectionPromptModifier: ViewModifier {
  @Binding var prompt: SectionPrompt?
  let store: CustomSectionStore
  @State private var name = ""
  @State private var presented: SectionPrompt?

  public init(prompt: Binding<SectionPrompt?>, store: CustomSectionStore) {
    _prompt = prompt
    self.store = store
  }

  public func body(content: Content) -> some View {
    content
      .alert(
        presented?.title ?? "",
        isPresented: Binding(get: { presented != nil }, set: { if !$0 { dismiss() } }),
        presenting: presented
      ) { prompt in
        TextField("Name", text: $name)
        Button(prompt.confirmTitle) { confirm(prompt) }
        Button("Cancel", role: .cancel) {}
      }
      .focusesAlertTextField(when: presented != nil)
      .onChange(of: prompt) { present(prompt) }
  }

  private func present(_ prompt: SectionPrompt?) {
    name = prompt?.initialName ?? ""
    presented = prompt
  }

  private func dismiss() {
    presented = nil
    prompt = nil
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
