import CodevisorClient
import SwiftUI

public struct BrowserFaviconImage<Content: View, Placeholder: View>: View {
  private let reference: String?
  private let client: (any BrowserFaviconClienting)?
  private let content: (Image) -> Content
  private let placeholder: Placeholder

  public init(
    reference: String?, client: (any BrowserFaviconClienting)?,
    @ViewBuilder content: @escaping (Image) -> Content, @ViewBuilder placeholder: () -> Placeholder
  ) {
    self.reference = reference
    self.client = client
    self.content = content
    self.placeholder = placeholder()
  }

  public var body: some View {
    Group {
      if let image = BrowserFaviconStore.shared.image(reference) {
        content(Image(decorative: image, scale: 1))
      } else {
        placeholder
      }
    }
    .task(id: reference) { await BrowserFaviconStore.shared.load(reference, from: client) }
  }
}
