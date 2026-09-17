import CodevisorCore
import SwiftUI

/// Shared semantics and native controls; each app supplies its harness icons.
public struct HarnessGlobalSection<Icon: View>: View {
  @Environment(AppEnvironment.self) private var environment
  private let model: HarnessGlobalModel
  private let icon: (String, String) -> Icon
  private let onAccounts: (HarnessFleet.Setting, Bool) -> Void

  public init(
    model: HarnessGlobalModel, onAccounts: @escaping (HarnessFleet.Setting, Bool) -> Void,
    @ViewBuilder icon: @escaping (String, String) -> Icon
  ) {
    self.model = model
    self.onAccounts = onAccounts
    self.icon = icon
  }

  private var settings: [HarnessFleet.Setting] {
    HarnessFleet.settings(environment.configSync).map { setting in
      guard let harness = model.catalog.first(where: { $0.id == setting.id }) else { return setting }
      var result = setting
      result.name = harness.name
      result.symbolName = harness.symbolName
      return result
    }
  }

  public var body: some View {
    Section {
      ForEach(settings) { setting in
        let state = HarnessRowState.shared(
          harnessId: setting.id, sync: environment.configSync,
          authRequired: model.catalog.first(where: { $0.id == setting.id })?.auth?.resolvedState != .notRequired)
        HarnessSettingsRow(
          name: setting.name, state: state,
          isEnabled: Binding(
            get: { setting.enabled },
            set: { enabled in
              var next = setting
              next.enabled = enabled
              HarnessFleet.set(next, in: environment.configSync)
            }),
          signIn: { onAccounts(setting, true) }
        ) {
          icon(setting.id, setting.symbolName)
        } actions: {
          if state.showsAccounts {
            Button("Accounts…", systemImage: "person.crop.circle") { onAccounts(setting, false) }
            Divider()
          }
          Button("Uninstall…", role: .destructive) { model.uninstall = setting }
        }
      }
    } footer: {
      #if os(macOS)
        HarnessAddButton(model: model, icon: icon)
      #endif
    }
  }
}
