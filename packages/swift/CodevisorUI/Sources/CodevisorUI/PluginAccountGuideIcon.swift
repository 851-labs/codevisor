import CodevisorCore
import SwiftUI

public struct PluginAccountGuideIcon: View {
  let model: PluginAccountGuideModel
  let side: CGFloat

  public init(model: PluginAccountGuideModel, side: CGFloat) {
    self.model = model
    self.side = side
  }

  public var body: some View {
    if let catalogId = model.catalogId {
      PluginCatalogIcon(
        pluginId: catalogId, name: model.spec.label, host: nil, namespace: "plugin-catalog", client: model.client,
        side: side)
    }
  }
}
