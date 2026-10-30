import CodevisorCore
import CodevisorUI
import SwiftUI

struct ProjectCloneLocationRow: View {
  let machine: CodevisorMachine
  let client: any CodevisorServerClienting

  @State private var settings: ServerProjectCloneSettings?
  @State private var draft = ""
  @State private var errorMessage: String?

  var body: some View {
    LabeledContent {
      HStack(spacing: 8) {
        TextField("Clone folder", text: $draft, prompt: Text(settings?.defaultBaseFolder ?? "~/codevisor/repos"))
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
          .frame(width: 300)
          .onSubmit { save(draft) }
          .disabled(settings == nil)
          .help(draft)
        if let settings, settings.baseFolder != settings.defaultBaseFolder {
          Button("Reset") { save(nil) }
            .help("Use \(settings.defaultBaseFolder)")
        }
      }
    } label: {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        MachineIconView(machineId: machine.id)
        VStack(alignment: .leading, spacing: 2) {
          Text(machine.name)
          if let errorMessage {
            Text(errorMessage)
              .font(.callout)
              .foregroundStyle(.red)
          }
        }
      }
    }
    .task(id: machine.id) {
      do {
        let loaded = try await client.projectCloneSettings()
        settings = loaded
        draft = loaded.baseFolder
      } catch {
        errorMessage = serverErrorMessage(error)
      }
    }
  }

  private func save(_ folder: String?) {
    Task {
      do {
        let saved = try await client.updateProjectCloneSettings(baseFolder: folder)
        settings = saved
        draft = saved.baseFolder
        errorMessage = nil
      } catch {
        errorMessage = serverErrorMessage(error)
      }
    }
  }
}
