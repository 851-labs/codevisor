import CodevisorCore
import SwiftUI

public struct SandboxAddProfileSheet: View {
  enum Page: Hashable {
    case providers
    case details(choiceId: String)
  }

  @Environment(\.dismiss) private var dismiss
  private let model: SandboxSettingsModel
  private let client: any CodevisorServerClienting
  @State private var path: [Page] = []
  @State private var removingAccount: ServerSandboxAccount?

  public init(model: SandboxSettingsModel, client: any CodevisorServerClienting) {
    self.model = model
    self.client = client
  }

  public var body: some View {
    NavigationStack(path: $path) {
      SandboxSheetPage(title: "Add Profile", onCancel: { dismiss() }) {
        Form {
          SandboxSheetError(message: model.errorMessage)
          if model.accounts.isEmpty {
            choices(model.providerChoices)
          } else {
            setUpChoices
          }
        }
        .formStyle(.grouped)
      }
      .navigationDestination(for: Page.self, destination: page)
    }
    #if os(macOS)
      .sheetSize(.list)
    #endif
    .onAppear { model.errorMessage = nil }
    .alert(removalTitle, isPresented: removalShown, presenting: removingAccount) { account in
      Button("Remove", role: .destructive) { Task { await model.delete(account, using: client) } }
      Button("Cancel", role: .cancel) {}
    }
  }

  @ViewBuilder
  private var setUpChoices: some View {
    Section {
      ForEach(model.setUpChoices) { choice in
        SandboxRemovableRow(account: choice.account, onRemove: { removingAccount = $0 }) {
          row(choice)
        }
      }
    }
    Section {
      SandboxChoiceRow(title: "Add Provider…", systemImage: "plus") { path.append(.providers) }
    }
  }

  @ViewBuilder
  private func page(_ page: Page) -> some View {
    switch page {
    case .providers:
      SandboxSheetPage(title: "Add Provider", showsCancel: false, onCancel: { dismiss() }) {
        Form { choices(model.signInChoices) }
          .formStyle(.grouped)
      }
    case let .details(choiceId):
      if let choice = model.choice(id: choiceId) {
        SandboxProfileDetailsPage(
          choice: choice, model: model, client: client, onCancel: { dismiss() }, onCreated: { dismiss() })
      }
    }
  }

  private func choices(_ choices: [SandboxSetupChoice]) -> some View {
    Section {
      ForEach(choices) { row($0) }
    }
  }

  private func row(_ choice: SandboxSetupChoice) -> some View {
    SandboxChoiceRow(
      title: model.title(of: choice),
      systemImage: SandboxTarget.systemImage(forProvider: choice.provider.id),
      isUntested: !choice.provider.tested
    ) {
      path.append(.details(choiceId: choice.id))
    }
  }

  private var removalTitle: String {
    "Remove “\(removingAccount.map(model.title(of:)) ?? "")”?"
  }

  private var removalShown: Binding<Bool> {
    Binding(get: { removingAccount != nil }, set: { if !$0 { removingAccount = nil } })
  }
}
