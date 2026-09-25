import ComposableArchitecture
import SwiftUI

/// The toolbar's Dynamic Resolution switch (851-2340), shared by the app and
/// the rig: on, the remote desktop follows the pane at the Mac's resolution;
/// off, it keeps its own size, scaled to fit. `persist` stores the machine's
/// choice (the reducer doesn't know which machine it is).
public struct ScreenSharingDynamicResolutionToggle: View {
  let store: StoreOf<ScreenSharingViewer>
  let persist: (Bool) -> Void

  public init(store: StoreOf<ScreenSharingViewer>, persist: @escaping (Bool) -> Void) {
    self.store = store
    self.persist = persist
  }

  public var body: some View {
    Toggle(
      isOn: Binding(
        get: { store.dynamicResolution && available == true },
        set: { _ in
          store.send(.dynamicResolutionToggled)
          persist(store.dynamicResolution)
        })
    ) {
      Label("Dynamic Resolution", systemImage: "arrow.up.left.and.arrow.down.right")
        .labelStyle(.iconOnly)
    }
    .toggleStyle(.button)
    .accessibilityLabel("Dynamic Resolution")
    // A host that can't change its desktop's size or scale (macOS Screen Sharing over VNC):
    // the button can't do anything, so it's off until the session knows (851-2368).
    .disabled(available != true)
    .help(help)
  }

  private var available: Bool? { store.endpoint?.resolutionAvailability.available }

  private var help: String {
    switch available {
    case false: "This machine can't change its resolution over this connection"
    case nil: "Dynamic Resolution: waiting for the remote desktop"
    case true:
      store.dynamicResolution
        ? "Dynamic Resolution is on: the remote desktop matches this pane at your Mac's resolution"
        : "Dynamic Resolution is off: the remote desktop keeps its own size, scaled to fit"
    }
  }
}

/// Mutes or unmutes the host's sound (851-2379), in the app's and the rig's toolbars.
public struct ScreenSharingMuteButton: View {
  @Bindable var audio: ScreenSharingAudioControl

  public init(audio: ScreenSharingAudioControl) { self.audio = audio }

  public var body: some View {
    Toggle(isOn: $audio.enabled) {
      Image(systemName: audio.enabled ? "speaker.wave.2" : "speaker.slash")
    }
    .toggleStyle(.button)
    .accessibilityLabel(audio.enabled ? "Mute" : "Unmute")
    .help(audio.enabled ? "Mute this machine's sound" : "Play this machine's sound")
  }
}
