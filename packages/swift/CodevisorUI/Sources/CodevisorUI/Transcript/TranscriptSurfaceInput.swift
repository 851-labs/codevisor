import CodevisorCore
import CoreGraphics
import QuartzCore
import StreamMarkdown
import SwiftUI
import TranscriptKit

public typealias TranscriptVirtualRow = TranscriptPresentationRow

public struct TranscriptScrollCommand: Equatable, Sendable {
  public var token = 0

  public init(token: Int = 0) {
    self.token = token
  }
}

public enum TranscriptPresentationRole: Equatable, Sendable {
  case foreground
  case prewarming
}

@MainActor
public struct TranscriptSurfaceInput {
  public var sessionController: SessionController
  public var rows: [TranscriptVirtualRow]
  public var activeRows: [TranscriptVirtualRow]
  public var hiddenActiveStreamIDs: [String]
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
  public var isAwaitingFirstActiveProjection: Bool
  public var activeTextRestorationID: String?
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
    hiddenActiveStreamIDs: [String] = [],
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
    activeTextRestorationID: String? = nil,
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
    self.hiddenActiveStreamIDs = hiddenActiveStreamIDs
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
    self.activeTextRestorationID = activeTextRestorationID
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
  public var markdownImageLoader: MarkdownImageLoader?
  public var openMarkdownLink: (@MainActor (URL) -> Bool)?
  public var markdownImageActions: MarkdownImageActions?
  public var markdownWebLinkActions: MarkdownWebLinkActions?
  public var onSendAnimationStarted: @MainActor (UserSendAnimationRequest) -> Void
  public var onEarlierHistoryCollapseChange: @MainActor (TranscriptEarlierHistoryCollapse?) -> Void

  public init(
    claimSendAnimation: @escaping @MainActor (UserSendAnimationRequest) -> Bool,
    rowContent: @escaping @MainActor (TranscriptVirtualRow) -> AnyView,
    onViewportChange: @escaping @MainActor (SessionScrollState) -> Void,
    onBottomStateChange: @escaping @MainActor (Bool) -> Void,
    onFollowStateChange: @escaping @MainActor (Bool) -> Void,
    onNearTop: @escaping @MainActor () -> Bool,
    onOlderHistoryPresented: @escaping @MainActor (UInt64) -> Void = { _ in },
    onSendAnimationCompleted: @escaping @MainActor (UserSendAnimationRequest) -> Void = { _ in },
    markdownImageLoader: MarkdownImageLoader? = nil,
    openMarkdownLink: (@MainActor (URL) -> Bool)? = nil,
    markdownImageActions: MarkdownImageActions? = nil,
    markdownWebLinkActions: MarkdownWebLinkActions? = nil,
    onSendAnimationStarted: @escaping @MainActor (UserSendAnimationRequest) -> Void = { _ in },
    onEarlierHistoryCollapseChange: @escaping @MainActor (TranscriptEarlierHistoryCollapse?) -> Void = { _ in }
  ) {
    self.claimSendAnimation = claimSendAnimation
    self.rowContent = rowContent
    self.onViewportChange = onViewportChange
    self.onBottomStateChange = onBottomStateChange
    self.onFollowStateChange = onFollowStateChange
    self.onNearTop = onNearTop
    self.onOlderHistoryPresented = onOlderHistoryPresented
    self.onSendAnimationCompleted = onSendAnimationCompleted
    self.markdownImageLoader = markdownImageLoader
    self.openMarkdownLink = openMarkdownLink
    self.markdownImageActions = markdownImageActions
    self.markdownWebLinkActions = markdownWebLinkActions
    self.onSendAnimationStarted = onSendAnimationStarted
    self.onEarlierHistoryCollapseChange = onEarlierHistoryCollapseChange
  }
}

public final class TranscriptSendAnimationCompletion: NSObject, CAAnimationDelegate {
  private let completion: (Bool) -> Void

  public init(completion: @escaping (Bool) -> Void) {
    self.completion = completion
  }

  public func animationDidStop(_: CAAnimation, finished: Bool) {
    completion(finished)
  }
}
