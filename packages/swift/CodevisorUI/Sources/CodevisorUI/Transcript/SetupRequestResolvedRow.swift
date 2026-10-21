import SwiftUI

struct SetupRequestResolvedRow: View {
  let copy: SetupRequestCopy

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: copy.symbol)
        .font(.title3)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(copy.resolvedTitle)
        .font(.callout.weight(.semibold))
        .foregroundStyle(.secondary)
      Spacer(minLength: 8)
      SetupRequestStatusIcon(state: copy.request.state)
    }
  }
}
