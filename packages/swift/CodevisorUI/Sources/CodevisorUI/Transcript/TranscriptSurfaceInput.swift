import CodevisorCore
import CoreGraphics
import QuartzCore
import StreamMarkdown
import SwiftUI
import TranscriptKit

/// The platform scroll views only mount and measure projected rows. The
/// transcript-wide row construction itself lives in CodevisorCore and runs off
/// the UI actor.
public typealias TranscriptVirtualRow = TranscriptPresentationRow

/// A monotonically bumped token. Changing it asks the surface to scroll to the
/// bottom and resume following the latest row.
public struct TranscriptScrollCommand: Equatable, Sendable {
  public var token = 0

  public init(token: Int = 0) {
    self.token = token
  }
}

/// A promoted new chat briefly has two transcript surfaces backed by the same
/// controller: the visible sheet and the workspace being mounted beneath it.
/// Only the foreground surface may consume presentation events or publish
/// viewport state; the prewarming surface is limited to layout and measurement.
public enum TranscriptPresentationRole: Equatable, Sendable {
  case foreground
  case prewarming
}

/// Everything a native transcript surface receives per SwiftUI update, minus
/// closures. Fields that only one platform consumes carry defaults so the
/// SwiftUI boundary can construct the same value on both platforms.
@MainActor
public struct TranscriptSurfaceInput {
  public var sessionController: SessionController
  public var rows: [TranscriptVirtualRow]
  public var activeRows: [TranscriptVirtualRow]
  public var activeRowsVersion: TranscriptRowSetRevision
  public var rowsVersion: TranscriptRowSetRevision
  public var projectionRevision: UInt64
  public var initialState: SessionScrollState?
  public var followsLatest: Bool
  public var hasOlderHistory: Bool
  public var showsOlderHistoryLoadingIndicator: Bool
  public var olderHistoryPresentationTarget: TranscriptPaginationPresentationTarget?
  public var isLoadingInitialHistory: Bool
  public var isPreparingInitialProjection: Bool
  public var isActiveProjectionPending: Bool
  /// No precise active projection has been published yet for the current
  /// active item, so the aggregate placeholder is all the surface has.
  public var isAwaitingFirstActiveProjection: Bool
  public var layoutFingerprint: Int
  public var scrollCommand: TranscriptScrollCommand
  public var sendAnimationRequest: UserSendAnimationRequest?
  public var sendAnimationSourceFrame: CGRect?
  public var presentationRole: TranscriptPresentationRole
  public var textAnimationRegistry: StreamingTextAnimationRegistry
  public var allowsLiveTextAnimation: Bool
  public var reduceMotion: Bool
  public var scrollIndicatorBottomInset: CGFloat

  public init(
    sessionController: SessionController,
    rows: [TranscriptVirtualRow],
    activeRows: [TranscriptVirtualRow],
    activeRowsVersion: TranscriptRowSetRevision,
    rowsVersion: TranscriptRowSetRevision,
    projectionRevision: UInt64,
    initialState: SessionScrollState?,
    followsLatest: Bool,
    hasOlderHistory: Bool,
    showsOlderHistoryLoadingIndicator: Bool,
    olderHistoryPresentationTarget: TranscriptPaginationPresentationTarget? = nil,
    isLoadingInitialHistory: Bool,
    isPreparingInitialProjection: Bool,
    isActiveProjectionPending: Bool,
    isAwaitingFirstActiveProjection: Bool = false,
    layoutFingerprint: Int,
    scrollCommand: TranscriptScrollCommand,
    sendAnimationRequest: UserSendAnimationRequest?,
    sendAnimationSourceFrame: CGRect? = nil,
    presentationRole: TranscriptPresentationRole = .foreground,
    textAnimationRegistry: StreamingTextAnimationRegistry,
    allowsLiveTextAnimation: Bool = true,
    reduceMotion: Bool,
    scrollIndicatorBottomInset: CGFloat = 0
  ) {
    self.sessionController = sessionController
    self.rows = rows
    self.activeRows = activeRows
    self.activeRowsVersion = activeRowsVersion
    self.rowsVersion = rowsVersion
    self.projectionRevision = projectionRevision
    self.initialState = initialState
    self.followsLatest = followsLatest
    self.hasOlderHistory = hasOlderHistory
    self.showsOlderHistoryLoadingIndicator = showsOlderHistoryLoadingIndicator
    self.olderHistoryPresentationTarget = olderHistoryPresentationTarget
    self.isLoadingInitialHistory = isLoadingInitialHistory
    self.isPreparingInitialProjection = isPreparingInitialProjection
    self.isActiveProjectionPending = isActiveProjectionPending
    self.isAwaitingFirstActiveProjection = isAwaitingFirstActiveProjection
    self.layoutFingerprint = layoutFingerprint
    self.scrollCommand = scrollCommand
    self.sendAnimationRequest = sendAnimationRequest
    self.sendAnimationSourceFrame = sendAnimationSourceFrame
    self.presentationRole = presentationRole
    self.textAnimationRegistry = textAnimationRegistry
    self.allowsLiveTextAnimation = allowsLiveTextAnimation
    self.reduceMotion = reduceMotion
    self.scrollIndicatorBottomInset = scrollIndicatorBottomInset
  }
}

#if canImport(UIKit)
  import UIKit

  /// The real virtualized row is the animation visual for a promoted first
  /// send. Its snapshot and final window-space frame let the presentation
  /// layer reuse the ordinary row animation without inventing another bubble
  /// view.
  @MainActor
  public struct TranscriptSendAnimationTarget {
    public let rowFrame: CGRect
    public let rowSnapshot: UIView

    public init(rowFrame: CGRect, rowSnapshot: UIView) {
      self.rowFrame = rowFrame
      self.rowSnapshot = rowSnapshot
    }
  }
#endif

/// The closures a native transcript surface calls back into SwiftUI with.
/// Callbacks that only one platform consumes default to no-ops.
@MainActor
public struct TranscriptSurfaceCallbacks {
  public var claimSendAnimation: @MainActor (UserSendAnimationRequest) -> Bool
  public var rowContent: @MainActor (TranscriptVirtualRow) -> AnyView
  public var onViewportChange: @MainActor (SessionScrollState) -> Void
  public var onBottomStateChange: @MainActor (Bool) -> Void
  public var onFollowStateChange: @MainActor (Bool) -> Void
  public var onNearTop: @MainActor () -> Bool
  public var onOlderHistoryPresented: @MainActor (UInt64) -> Void
  public var onSendAnimationCompleted: @MainActor (UserSendAnimationRequest) -> Void
  /// Opens a Markdown link. Returns true when the link was handled (a
  /// workspace file shown in Quick Look); false lets the platform open it.
  public var openMarkdownLink: (@MainActor (URL) -> Bool)?
  #if canImport(UIKit)
    public var onSendAnimationStarted: (@MainActor (UserSendAnimationRequest, TranscriptSendAnimationTarget) -> Bool)?
  #endif

  #if canImport(UIKit)
    public init(
      claimSendAnimation: @escaping @MainActor (UserSendAnimationRequest) -> Bool,
      rowContent: @escaping @MainActor (TranscriptVirtualRow) -> AnyView,
      onViewportChange: @escaping @MainActor (SessionScrollState) -> Void,
      onBottomStateChange: @escaping @MainActor (Bool) -> Void,
      onFollowStateChange: @escaping @MainActor (Bool) -> Void,
      onNearTop: @escaping @MainActor () -> Bool,
      onOlderHistoryPresented: @escaping @MainActor (UInt64) -> Void = { _ in },
      onSendAnimationCompleted: @escaping @MainActor (UserSendAnimationRequest) -> Void = { _ in },
      openMarkdownLink: (@MainActor (URL) -> Bool)? = nil,
      onSendAnimationStarted: (
        @MainActor (UserSendAnimationRequest, TranscriptSendAnimationTarget) -> Bool
      )? = nil
    ) {
      self.claimSendAnimation = claimSendAnimation
      self.rowContent = rowContent
      self.onViewportChange = onViewportChange
      self.onBottomStateChange = onBottomStateChange
      self.onFollowStateChange = onFollowStateChange
      self.onNearTop = onNearTop
      self.onOlderHistoryPresented = onOlderHistoryPresented
      self.onSendAnimationCompleted = onSendAnimationCompleted
      self.openMarkdownLink = openMarkdownLink
      self.onSendAnimationStarted = onSendAnimationStarted
    }
  #else
    public init(
      claimSendAnimation: @escaping @MainActor (UserSendAnimationRequest) -> Bool,
      rowContent: @escaping @MainActor (TranscriptVirtualRow) -> AnyView,
      onViewportChange: @escaping @MainActor (SessionScrollState) -> Void,
      onBottomStateChange: @escaping @MainActor (Bool) -> Void,
      onFollowStateChange: @escaping @MainActor (Bool) -> Void,
      onNearTop: @escaping @MainActor () -> Bool,
      onOlderHistoryPresented: @escaping @MainActor (UInt64) -> Void = { _ in },
      onSendAnimationCompleted: @escaping @MainActor (UserSendAnimationRequest) -> Void = { _ in },
      openMarkdownLink: (@MainActor (URL) -> Bool)? = nil
    ) {
      self.claimSendAnimation = claimSendAnimation
      self.rowContent = rowContent
      self.onViewportChange = onViewportChange
      self.onBottomStateChange = onBottomStateChange
      self.onFollowStateChange = onFollowStateChange
      self.onNearTop = onNearTop
      self.onOlderHistoryPresented = onOlderHistoryPresented
      self.onSendAnimationCompleted = onSendAnimationCompleted
      self.openMarkdownLink = openMarkdownLink
    }
  #endif
}

/// Retained for the lifetime of a Core Animation group so send and disclosure
/// presentations can wait for the real row's presentation completion.
public final class TranscriptSendAnimationCompletion: NSObject, CAAnimationDelegate {
  private let completion: (Bool) -> Void

  public init(completion: @escaping (Bool) -> Void) {
    self.completion = completion
  }

  public func animationDidStop(_: CAAnimation, finished: Bool) {
    completion(finished)
  }
}
