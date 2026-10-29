import CodevisorCore
import CodevisorUI
import SwiftUI

enum BotSectionPrompt: Identifiable {
  case create(moving: Bot?)
  case rename(BotSection)

  var id: String {
    switch self {
    case .create: "create"
    case let .rename(section): "rename:\(section.id)"
    }
  }

  var title: String {
    switch self {
    case .create: "New Section"
    case .rename: "Rename Section"
    }
  }

  var confirmTitle: String {
    switch self {
    case .create: "Create"
    case .rename: "Rename"
    }
  }

  var initialName: String {
    switch self {
    case .create: ""
    case let .rename(section): section.name
    }
  }
}

struct BotSectionPromptModifier: ViewModifier {
  @Environment(AppEnvironment.self) private var environment
  @Binding var prompt: BotSectionPrompt?
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

  private func confirm(_ prompt: BotSectionPrompt) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    switch prompt {
    case let .create(moving):
      let section = environment.botSections.create(name: trimmed)
      if let moving { environment.botSections.move(bot: moving.id, to: section.id) }
    case let .rename(section):
      environment.botSections.rename(section.id, to: trimmed)
    }
  }
}
