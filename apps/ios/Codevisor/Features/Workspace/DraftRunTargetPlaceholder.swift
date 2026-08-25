import CodevisorCore
import SwiftUI

/// The new-chat screen before any project exists: an empty page whose one
/// action opens the machine → project → run-location sheet (its project step
/// hosts "New Project…"). Owns the sheet presentation so `WorkspaceScreen`
/// only supplies what to do with the pick.
struct DraftRunTargetPlaceholder: View {
    let onPicked: (Project, Bool) -> Void

    @State private var showsPicker = false

    var body: some View {
        VStack {
            Spacer()
            Button {
                showsPicker = true
            } label: {
                Label("Choose a Project…", systemImage: "folder.fill")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showsPicker) {
            RunTargetPickerSheet(onFinish: onPicked)
        }
    }
}
