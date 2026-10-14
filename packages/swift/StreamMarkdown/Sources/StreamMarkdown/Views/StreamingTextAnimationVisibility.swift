import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
public final class StreamingTextAnimationVisibility {
  private let presentationID = UUID()
  private var activeEntranceAnimationSourceIDs: Set<UUID> = []
  public private(set) var generation = 0
  public private(set) var isVisible: Bool

  public var hasActiveEntranceAnimation: Bool {
    isVisible && !activeEntranceAnimationSourceIDs.isEmpty
  }

  public var presentationKey: String {
    "\(presentationID.uuidString):\(generation)"
  }

  public init(initiallyVisible: Bool = true) {
    isVisible = initiallyVisible
  }

  public func appear() {
    guard !isVisible else { return }
    generation &+= 1
    activeEntranceAnimationSourceIDs.removeAll()
    isVisible = true
  }

  public func disappear() {
    activeEntranceAnimationSourceIDs.removeAll()
    isVisible = false
  }

  public func setEntranceAnimationActive(_ active: Bool, sourceID: UUID) {
    guard isVisible else {
      activeEntranceAnimationSourceIDs.remove(sourceID)
      return
    }
    if active {
      activeEntranceAnimationSourceIDs.insert(sourceID)
    } else {
      activeEntranceAnimationSourceIDs.remove(sourceID)
    }
  }
}

private struct StreamingTextAnimationVisibilityKey: EnvironmentKey {
  static let defaultValue: StreamingTextAnimationVisibility? = nil
}

public extension EnvironmentValues {
  var streamingTextAnimationVisibility: StreamingTextAnimationVisibility? {
    get { self[StreamingTextAnimationVisibilityKey.self] }
    set { self[StreamingTextAnimationVisibilityKey.self] = newValue }
  }
}

private struct StreamingTextAnimationActivityReporter: ViewModifier {
  @Environment(\.streamingTextAnimationVisibility) private var visibility
  @State private var sourceID = UUID()
  @State private var isActive = false

  func body(content: Content) -> some View {
    content
      .onPreferenceChange(StreamingMarkdownEntranceAnimationPreferenceKey.self) { active in
        isActive = active
        visibility?.setEntranceAnimationActive(active, sourceID: sourceID)
      }
      .onAppear {
        visibility?.setEntranceAnimationActive(isActive, sourceID: sourceID)
      }
      .onChange(of: visibility?.presentationKey) {
        visibility?.setEntranceAnimationActive(isActive, sourceID: sourceID)
      }
      .onDisappear {
        visibility?.setEntranceAnimationActive(false, sourceID: sourceID)
      }
  }
}

private struct StreamingTextAnimationEphemeralGate: ViewModifier {
  @Environment(\.streamingTextAnimationVisibility) private var visibility

  func body(content: Content) -> some View {
    let isSuppressed = visibility?.hasActiveEntranceAnimation == true
    content
      .opacity(isSuppressed ? 0 : 1)
      .allowsHitTesting(!isSuppressed)
      .accessibilityHidden(isSuppressed)
      .animation(nil, value: isSuppressed)
  }
}

public extension View {
  func reportsStreamingTextAnimationActivity() -> some View {
    modifier(StreamingTextAnimationActivityReporter())
  }

  func suppressedDuringStreamingTextEntrance() -> some View {
    modifier(StreamingTextAnimationEphemeralGate())
  }
}
