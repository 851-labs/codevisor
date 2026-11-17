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
  let fillsRow: Bool
  let add: (ServerHarnessAuthMethod?) async -> Void

  public init(
    title: String, methods: [ServerHarnessAuthMethod], fillsRow: Bool = false,
    add: @escaping (ServerHarnessAuthMethod?) async -> Void
  ) {
    self.title = title
    self.methods = methods
    self.fillsRow = fillsRow
    self.add = add
  }

  public var body: some View {
    if fillsRow {
      control.buttonStyle(.plain).menuStyle(.button)
    } else {
      control
    }
  }

  @ViewBuilder private var control: some View {
    if methods.count > 1 {
      Menu {
        ForEach(methods) { method in
          Button(method.name) { Task { await add(method) } }
        }
      } label: {
        label("\(title)…")
      }
      .menuIndicator(.hidden)
    } else {
      Button {
        Task { await add(methods.first) }
      } label: {
        label(title)
      }
    }
  }

  private func label(_ text: String) -> some View {
    Label(text, systemImage: "plus")
      .frame(maxWidth: fillsRow ? .infinity : nil, alignment: .leading)
      .contentShape(Rectangle())
  }
}
