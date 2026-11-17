import CodevisorCore
import SwiftUI

public struct HarnessAddButton: View {
  @Environment(AppEnvironment.self) private var environment
  @Bindable private var model: HarnessGlobalModel

  public init(model: HarnessGlobalModel) {
    self.model = model
  }

  public var body: some View {
    #if os(macOS)
      HarnessAddMenu(
        isPresented: $model.showsPicker,
        harnesses: availableHarnesses,
        add: { model.add($0, in: environment) }
      )
    #else
      SettingsAddButton("Add Harness") { model.showsPicker = true }
        .sheet(isPresented: $model.showsPicker) { picker }
    #endif
  }

  private var availableHarnesses: [HarnessFleet.CatalogEntry] {
    let added = Set(HarnessFleet.settings(environment.configSync).map(\.id))
    return HarnessFleet.catalog(environment.configSync).filter { !added.contains($0.id) }
  }

  #if os(iOS)
    private var picker: some View {
      HarnessPickerSheet(
        harnesses: availableHarnesses,
        add: { model.add($0, in: environment) }
      )
    }
  #endif
}
