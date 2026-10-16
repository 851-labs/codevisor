import CodevisorCore
import SwiftUI

public struct HarnessSignInMethods: View {
  let methods: [ServerHarnessAuthMethod]
  let model: HarnessAccountListModel
  let choose: (ServerHarnessAuthMethod) -> Void

  public init(
    methods: [ServerHarnessAuthMethod], model: HarnessAccountListModel,
    choose: @escaping (ServerHarnessAuthMethod) -> Void
  ) {
    self.methods = methods
    self.model = model
    self.choose = choose
  }

  public var body: some View {
    VStack(spacing: 0) {
      Form {
        Section("Choose how to sign in") {
          ForEach(methods) { method in
            Button {
              choose(method)
            } label: {
              HStack {
                Text(method.name)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
      }
      .formStyle(.grouped)
      .disabled(model.isWorking)
      if let error = model.errorMessage {
        Text(error).font(.callout).foregroundStyle(.red).padding()
      }
    }
    .harnessWorking(model.operation)
  }
}

public struct HarnessAddAccountControl: View {
  let title: String
  let methods: [ServerHarnessAuthMethod]
  let add: (ServerHarnessAuthMethod?) async -> Void

  public init(
    title: String, methods: [ServerHarnessAuthMethod],
    add: @escaping (ServerHarnessAuthMethod?) async -> Void
  ) {
    self.title = title
    self.methods = methods
    self.add = add
  }

  public var body: some View {
    if methods.count > 1 {
      Menu {
        ForEach(methods) { method in
          Button(method.name) { Task { await add(method) } }
        }
      } label: {
        Label("\(title)…", systemImage: "plus")
      }
      .menuIndicator(.hidden)
    } else {
      Button {
        Task { await add(methods.first) }
      } label: {
        Label(title, systemImage: "plus")
      }
    }
  }
}
