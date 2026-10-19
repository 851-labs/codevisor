import SwiftUI
import AppKit
import CodevisorCore
import CodevisorCoreMac
import CodevisorUI

struct ComputerUsePermissionRowsView: View {
  let model: ComputerUsePermissionsModel
  var includesFullDiskAccess = false
  var embedded = false
  @Environment(\.controlActiveState) private var controlActiveState

  var body: some View {
    VStack(alignment: .leading, spacing: embedded ? 0 : 12) {
      PermissionCard(embedded: embedded) {
        PermissionRow(
          symbol: "accessibility",
          title: "Accessibility",
          subtitle: "Reads on-screen text and controls",
          grantedLabel: model.isAccessibilityGranted ? "Granted" : nil,
          embedded: embedded
        ) {
          PermissionActionButton("Allow…") { model.requestAccessibility() }
        }
        Divider()
        PermissionRow(
          symbol: "rectangle.dashed.badge.record",
          title: "Screen Recording",
          subtitle: "Sees app windows",
          grantedLabel: model.isScreenRecordingGranted ? "Granted" : nil,
          embedded: embedded
        ) {
          PermissionActionButton("Allow…") { model.requestScreenRecording() }
        }
        if includesFullDiskAccess {
          Divider()
          PermissionRow(
            symbol: "internaldrive",
            title: "Full Disk Access",
            subtitle: "Accesses protected files",
            grantedLabel: model.isFullDiskAccessGranted ? "Granted" : nil,
            embedded: embedded
          ) {
            PermissionActionButton("Allow…") { model.requestFullDiskAccess() }
          }
        }
      }

      if model.screenRecordingGrantedThisRun {
        relaunchNudge
          .padding(.top, embedded ? 8 : 0)
      }
    }
    .task {
      while !Task.isCancelled {
        model.refresh()
        try? await Task.sleep(for: .seconds(1))
      }
    }
    .onChange(of: controlActiveState) { _, _ in
      model.refresh()
    }
  }

  private var relaunchNudge: some View {
    HStack(spacing: 10) {
      Image(systemName: "arrow.clockwise.circle.fill")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)

      Text("Screen Recording applies after Codevisor restarts")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)

      Button("Restart Now") { AppRelauncher.relaunch() }
        .controlSize(.small)
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
  }
}

struct ComputerUsePermissionsGateView: View {
  var onComplete: () -> Void
  var onSkip: () -> Void

  @State private var model = ComputerUsePermissionsModel(
    probes: AppPreview.isRunning ? .granted : .live
  )

  var body: some View {
    ZStack {
      Color.black.opacity(0.28)
        .ignoresSafeArea()
        .onTapGesture {}

      card
    }
  }

  private var card: some View {
    VStack(spacing: 16) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .frame(width: 64, height: 64)
        .shadow(color: .black.opacity(0.2), radius: 8, y: 5)
        .accessibilityHidden(true)

      VStack(spacing: 4) {
        Text("Allow Computer Use")
          .font(.title2.bold())
        Text("Codevisor uses these to operate apps when you ask.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }

      ComputerUsePermissionRowsView(model: model)

      HStack {
        Button("Set Up Later") { onSkip() }
        Spacer()
        Button("Continue") { onComplete() }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(!model.allGranted)
      }
      .padding(.top, 4)
    }
    .padding(28)
    .frame(width: 480)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(.regularMaterial)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.08))
    )
    .shadow(color: .black.opacity(0.32), radius: 26, y: 12)
  }
}

#Preview("Permissions gate") {
  ComputerUsePermissionsGateView(onComplete: {}, onSkip: {})
    .frame(width: 900, height: 640)
}
