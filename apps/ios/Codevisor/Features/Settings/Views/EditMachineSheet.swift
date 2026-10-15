import CodevisorCore
import CodevisorUI
import SwiftUI

struct EditMachineSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var pickedIcon: String?
  private let shownIcon: String
  let onSave: (_ name: String, _ pickedIcon: String?) -> Void

  init(machine: CloudMachine, icon: MachineIcon, onSave: @escaping (_ name: String, _ pickedIcon: String?) -> Void) {
    self.onSave = onSave
    _name = State(initialValue: machine.name)
    shownIcon = icon.systemImage
  }

  private var icon: String { pickedIcon ?? shownIcon }

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
            onSave(trimmedName, pickedIcon)
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
      pickedIcon = choice.systemImage
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
