import CodevisorCore
import CodevisorUI
import SwiftUI

struct EditMachineSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var icon: String
  let onSave: (_ name: String, _ icon: String) -> Void

  init(machine: CloudMachine, onSave: @escaping (_ name: String, _ icon: String) -> Void) {
    self.onSave = onSave
    _name = State(initialValue: machine.name)
    _icon = State(
      initialValue: MachineIcon.choice(machine.icon)?.systemImage ?? MachineIcon.fallback
    )
  }

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Name", text: $name)
        } header: {
          Text("Name")
        }
        Section {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 66), spacing: 14)], spacing: 14) {
            ForEach(MachineIcon.choices) { choice in
              iconTile(choice)
            }
          }
          .padding(.vertical, 10)
        } header: {
          Text("Icon")
        }
      }
      .navigationTitle("Edit Machine")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            onSave(trimmedName, icon)
            dismiss()
          }
          .disabled(trimmedName.isEmpty)
        }
      }
    }
  }

  private func iconTile(_ choice: MachineIcon) -> some View {
    let isSelected = icon == choice.systemImage
    return Button {
      icon = choice.systemImage
    } label: {
      Image(systemName: choice.systemImage)
        .symbolVariant(.fill)
        .font(.title2)
        .foregroundStyle(.secondary)
        .frame(width: 52, height: 52)
        .background(.fill.tertiary, in: .circle)
        .padding(7)
        .overlay {
          if isSelected {
            Circle().strokeBorder(.tertiary, lineWidth: 3)
          }
        }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(choice.title)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}
