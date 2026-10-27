import CodevisorCore
import SwiftUI

public struct PluginIngressRow: View {
  let ingress: ServerPluginIngressURL

  public init(ingress: ServerPluginIngressURL) {
    self.ingress = ingress
  }

  public var body: some View {
    LabeledContent(ingress.title ?? "Webhook URL") {
      CopyableValue(value: ingress.url)
    }
  }
}
