#if os(macOS)
  import CodevisorCore
  import SwiftUI

  struct PluginConnectCapabilities: View {
    let capabilities: ServerPluginCapabilities
    @State private var expanded: String?

    private struct Group: Identifiable {
      let id: String
      let items: [Item]
    }

    private struct Item: Identifiable {
      let id: Int
      let name: String
      let detail: String?
    }

    private var groups: [Group] {
      [
        Group(id: "Tools", items: Self.items(capabilities.tools.map { ($0.name, $0.description) })),
        Group(id: "Skills", items: Self.items(capabilities.skills.map { ($0.name, $0.description) })),
        Group(id: "Events", items: Self.items(capabilities.events.map { ($0.name, $0.description) })),
        Group(id: "Panes", items: Self.items(capabilities.panes.map { ($0.title, nil) })),
      ].filter { !$0.items.isEmpty }
    }

    var body: some View {
      if !groups.isEmpty {
        PermissionCard {
          ForEach(groups) { group in
            if group.id != groups.first?.id { Divider() }
            header(group)
            if expanded == group.id { list(group) }
          }
        }
      }
    }

    private func header(_ group: Group) -> some View {
      Button {
        withAnimation(.snappy(duration: 0.2)) { expanded = expanded == group.id ? nil : group.id }
      } label: {
        HStack {
          Text(group.id)
          Spacer()
          Text(group.items.count, format: .number).foregroundStyle(.secondary)
          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(expanded == group.id ? 90 : 0))
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityValue(expanded == group.id ? "Expanded" : "Collapsed")
    }

    private func list(_ group: Group) -> some View {
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(group.items) { item in
            VStack(alignment: .leading, spacing: 1) {
              Text(item.name).font(.callout)
              if let detail = item.detail {
                Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .padding(.bottom, 10)
      }
      .frame(maxHeight: 180)
    }

    private static func items(_ named: [(String, String?)]) -> [Item] {
      named.enumerated().map { Item(id: $0.offset, name: $0.element.0, detail: $0.element.1) }
    }
  }
#endif
