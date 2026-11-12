import CodevisorClient
import CodevisorCoreMac
import ComposableArchitecture
import SwiftUI

struct MachineDesktopPreview: View {
  let session: MachineDesktopSession
  let isStreaming: Bool
  let onOpen: () -> Void
  @State private var registration = MachineDesktopRegistration.pending
  @State private var registrationAttempt = 0
  @State private var isHovered = false
  @State private var mount = UUID()

  var body: some View {
    if let viewer = session.preview.store {
      MachineDesktopCard(
        registration: registration, viewer: viewer, machineName: session.preview.machineName, isHovered: isHovered,
        onOpen: onOpen, onRetry: retry
      )
      .onHover { isHovered = $0 }
      .task(id: registrationAttempt) { await register() }
      .background {
        if registration == .registered, isStreaming {
          Color.clear
            .onAppear { session.preview.mounted(mount) }
            .onDisappear { session.preview.unmounted(mount) }
        }
      }
    }
  }

  private func register() async {
    do {
      try await session.register()
      registration = .registered
    } catch  where !isTaskCancellation(error) {
      registration = .failed(serverErrorMessage(error))
    } catch {}
  }

  private func retry() {
    guard case .failed = registration else {
      session.preview.store?.send(.retryButtonTapped)
      return
    }
    registration = .pending
    registrationAttempt += 1
  }
}
