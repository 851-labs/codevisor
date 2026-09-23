import CodevisorCore
import SwiftUI

/// A direct Sign In action only asks for the method when there is a choice.
///
/// Presented as a pushed step, with a header that frames it as picking a
/// method. Shown as a full replacement it read as a second "Sign In" —
/// the user had already said what they wanted and appeared to be asked
/// again — when the actual question is *how*.
public struct HarnessSignInMethods: View {
  @Environment(\.theme) private var theme
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
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(theme.textSecondary)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
      }
      .formStyle(.grouped)
      .disabled(model.isWorking)
      // No inline spinner: the running operation renders in the sheet's
      // chrome (see SheetActivityLabel), so this list cannot reflow while
      // a sign-in starts.
      if let error = model.errorMessage {
        Text(error).font(.callout).foregroundStyle(theme.statusError).padding()
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
        // A trailing ellipsis rather than a disclosure chevron. A "+" glyph
        // and a chevron on one control read as two separate affordances,
        // and the ellipsis is the platform's own way to say "this asks you
        // something first" — which is exactly what the method menu does.
        // Keeping the indicator hidden also means this control looks the
        // same whether a harness offers one sign-in method or several.
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
