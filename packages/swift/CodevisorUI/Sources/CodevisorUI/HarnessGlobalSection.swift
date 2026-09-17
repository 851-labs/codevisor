import CodevisorCore
import SwiftUI

/// Shared semantics and native controls; each app supplies its harness icons.
public struct HarnessGlobalSection<Icon: View>: View {
  @Environment(AppEnvironment.self) private var environment
  private let model: HarnessGlobalModel
  private let icon: (String, String) -> Icon
  private let onAccounts: (HarnessFleet.Setting) -> Void

  public init(
    model: HarnessGlobalModel, onAccounts: @escaping (HarnessFleet.Setting) -> Void,
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
        HStack(spacing: 10) {
          icon(setting.id, setting.symbolName).frame(width: 22)
          Text(setting.name)
          Spacer()
          Toggle(
            "Enable \(setting.name)",
            isOn: Binding(
              get: { setting.enabled },
              set: { enabled in
                var next = setting
                next.enabled = enabled
                HarnessFleet.set(next, in: environment.configSync)
              }
            )
          )
          .labelsHidden()
          .toggleStyle(.switch)
          Menu {
            if HarnessSharedCredentials(rawValue: setting.id) != nil
              || model.catalog.first(where: { $0.id == setting.id })?.auth?.resolvedState != .notRequired
            {
              Button("Accounts…", systemImage: "person.crop.circle") { onAccounts(setting) }
              Divider()
            }
            Button("Uninstall…", role: .destructive) { model.uninstall = setting }
          } label: {
            Image(systemName: "ellipsis.circle")
          }
          .accessibilityLabel("\(setting.name) options")
          #if os(macOS)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
          #endif
        }
      }
    } footer: {
      #if os(macOS)
        HarnessAddButton(model: model, icon: icon)
      #endif
    }
  }
}
