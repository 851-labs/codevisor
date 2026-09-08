import SwiftUI

public struct BrowserSuggestionList: View {
  @Bindable private var suggestions: BrowserSuggestions
  private let select: (BrowserSuggestion) -> Void

  public init(suggestions: BrowserSuggestions, select: @escaping (BrowserSuggestion) -> Void) {
    self.suggestions = suggestions; self.select = select
  }

  public var body: some View {
    ScrollViewReader { reader in
      ScrollView {
        VStack(alignment: .leading, spacing: 3) {
          ForEach(suggestions.items) { item in
            if item.kind == .search, item.id == suggestions.items.first(where: { $0.kind == .search })?.id {
              Text("Google Suggestions").font(.subheadline).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
            }
            Button {
              select(item)
            } label: {
              HStack(spacing: 12) {
                Image(systemName: item.kind == .page ? "globe" : "magnifyingglass").frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                  Text(item.title).font(.body).lineLimit(1)
                  if item.kind == .page {
                    Text(item.value).font(.subheadline).opacity(0.7).lineLimit(1).truncationMode(.middle)
                  }
                }
                Spacer(minLength: 0)
              }
              .padding(.horizontal, 12).padding(.vertical, 10)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(suggestions.selectedID == item.id ? Color.white : Color.primary)
            .background(suggestions.selectedID == item.id ? Color.accentColor : .clear, in: .rect(cornerRadius: 10))
            .accessibilityAddTraits(suggestions.selectedID == item.id ? [.isSelected] : [])
            .id(item.id)
          }
        }
        .padding(8)
      }
      .onChange(of: suggestions.selectedID) { _, id in if let id { reader.scrollTo(id) } }
    }
  }
}
