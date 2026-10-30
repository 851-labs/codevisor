import SwiftUI

public struct PluginListDisclosure<Rows: View>: View {
  private let title: String
  private let count: Int
  private let isLoading: Bool
  private let emptyText: String?
  private let message: String?
  private let rows: () -> Rows
  @State private var isExpanded = false

  public init(
    _ title: String,
    count: Int,
    isLoading: Bool = false,
    emptyText: String? = nil,
    message: String? = nil,
    @ViewBuilder rows: @escaping () -> Rows
  ) {
    self.title = title
    self.count = count
    self.isLoading = isLoading
    self.emptyText = emptyText
    self.message = message
    self.rows = rows
  }

  public var body: some View {
    Section {
      SettingsDisclosureRows(isExpanded: $isExpanded) {
        LabeledContent(title) {
          if isLoading {
            ProgressView().controlSize(.small)
          } else {
            Text(count, format: .number)
          }
        }
        .foregroundStyle(.primary)
      } content: {
        if count == 0 && !isLoading, let emptyText {
          Text(emptyText).foregroundStyle(.secondary)
        } else {
          rows()
        }
      }
    } footer: {
      if let message { Text(message).foregroundStyle(.red) }
    }
  }
}
