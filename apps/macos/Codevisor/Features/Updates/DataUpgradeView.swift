import CodevisorCore
import SwiftUI

/// Reusable launch gate for breaking data-version changes. The server owns
/// migration correctness; this view only reflects its durable batch progress.
struct DataUpgradeView: View {
    let progress: LocalDataUpgradeProgress
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: progress.state == "failed" ? "exclamationmark.triangle" : "shippingbox.and.arrow.backward")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(progress.state == "failed" ? Color.orange : Color.accentColor)

            VStack(spacing: 6) {
                Text(progress.state == "failed" ? "Update couldn’t be applied" : "Applying update")
                    .font(.title2.weight(.semibold))
                Text(progress.state == "failed"
                     ? "Your data is unchanged. Try the update again."
                     : "Codevisor will open when it’s ready.")
                    .foregroundStyle(.secondary)
            }

            if progress.state == "failed" {
                Button("Try Again", action: retry)
                    .buttonStyle(.borderedProminent)
            } else if let fraction = progress.fractionCompleted {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 280)
                    .accessibilityLabel("Applying update")
                    .accessibilityValue("\(Int(fraction * 100)) percent")
            } else {
                ProgressView()
                    .controlSize(.large)
                    .accessibilityLabel("Applying update")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview("Applying update") {
    DataUpgradeView(
        progress: LocalDataUpgradeProgress(
            state: "running",
            id: "canonical-chat-v1",
            name: "Updating chat history",
            completed: 42,
            total: 100,
            error: nil
        ),
        retry: {}
    )
    .frame(width: 720, height: 480)
}
