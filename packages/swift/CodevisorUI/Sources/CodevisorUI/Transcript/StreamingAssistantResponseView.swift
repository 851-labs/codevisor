import CodevisorCore
import StreamMarkdown
import SwiftUI

/// Renders a final response's Markdown slices and attachment previews on one
/// ordered animation timeline. A file preview is a document boundary: it waits
/// for the preceding Markdown to finish entering, fades as one native element,
/// and only then allows later Markdown to mount.
public struct StreamingAssistantResponseView<AttachmentContent: View>: View {
  private let turnID: UUID
  private let entryID: String
  private let markdown: String
  private let attachments: [Attachment]
  private let isGenerating: Bool
  private let animationPresentation: StreamingTextAnimationPresentation
  private let animationEnabled: Bool
  private let attachmentContent: (PreviewFile, String) -> AttachmentContent

  public init(
    turnID: UUID,
    entryID: String,
    markdown: String,
    attachments: [Attachment],
    isGenerating: Bool,
    animationPresentation: StreamingTextAnimationPresentation,
    animationEnabled: Bool = true,
    @ViewBuilder attachmentContent: @escaping (PreviewFile, String) -> AttachmentContent
  ) {
    self.turnID = turnID
    self.entryID = entryID
    self.markdown = markdown
    self.attachments = attachments
    self.isGenerating = isGenerating
    self.animationPresentation = animationPresentation
    self.animationEnabled = animationEnabled
    self.attachmentContent = attachmentContent
  }

  public var body: some View {
    let responseStreamID = TranscriptStreamingTextIdentity.main(
      turnID: turnID,
      entryID: entryID
    )
    StreamingAssistantResponseContent(
      turnID: turnID,
      entryID: entryID,
      responseStreamID: responseStreamID,
      markdown: markdown,
      attachments: attachments,
      isGenerating: isGenerating,
      animationPresentation: animationPresentation,
      animationEnabled: animationEnabled,
      attachmentContent: attachmentContent
    )
    // A final-answer candidate may demote while a newer text entry takes
    // its place. Its timeline and reveal ledger must not leak into the new
    // semantic response.
    .id(responseStreamID)
  }
}

private struct StreamingAssistantResponseContent<AttachmentContent: View>: View {
  let turnID: UUID
  let entryID: String
  let responseStreamID: String
  let markdown: String
  let attachments: [Attachment]
  let isGenerating: Bool
  let animationPresentation: StreamingTextAnimationPresentation
  let animationEnabled: Bool
  let attachmentContent: (PreviewFile, String) -> AttachmentContent

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var animationCoordinator = StreamingContentAnimationCoordinator()
  @State private var animationMount = StreamingAssistantResponseAnimationMount()
  @State private var animationMountRevision = 0
  @State private var entranceSequence = StreamingAssistantResponseEntranceSequence()
  @State private var entranceRevision = 0
  @State private var presentationState: StreamingAssistantResponsePresentationState
  @State private var presentationRevision = 0

  init(
    turnID: UUID,
    entryID: String,
    responseStreamID: String,
    markdown: String,
    attachments: [Attachment],
    isGenerating: Bool,
    animationPresentation: StreamingTextAnimationPresentation,
    animationEnabled: Bool,
    attachmentContent: @escaping (PreviewFile, String) -> AttachmentContent
  ) {
    self.turnID = turnID
    self.entryID = entryID
    self.responseStreamID = responseStreamID
    self.markdown = markdown
    self.attachments = attachments
    self.isGenerating = isGenerating
    self.animationPresentation = animationPresentation
    self.animationEnabled = animationEnabled
    self.attachmentContent = attachmentContent
    _presentationState = State(
      initialValue: StreamingAssistantResponsePresentationState(
        providerIsGenerating: isGenerating
      ))
  }

  var body: some View {
    let presentationComplete = presentationState.isComplete
    let presentsAnimation = !presentationComplete && animationEnabled
    let segments = assistantMarkdownSegments(
      markdown,
      attachments: attachments,
      // A syntactically complete local image is already a stable
      // document boundary. Resolve it while the answer is live so
      // provider completion never retroactively splits one rendered
      // Markdown surface around an image preview.
      includeServerPaths: true,
      includeUnreferencedAttachments: presentationComplete
    )
    let mount = animationMount.resolve(
      streamID: responseStreamID,
      presentation: animationPresentation
    )
    let entrance = entranceSequence.resolve(
      segments: segments,
      responseStreamID: responseStreamID,
      animationEnabled: presentsAnimation,
      animatesInitialContent: mount.animatesInitialContent,
      reduceMotion: reduceMotion
    )
    let presentationWork = presentationState.nextWork(
      pendingFileID: entrance.pendingFileID
    )
    let _ = animationMountRevision
    let _ = entranceRevision
    let _ = presentationRevision

    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
        if index < entrance.visibleSegmentCount {
          switch segment {
          case let .markdown(value):
            if !value.isEmpty {
              StreamingMarkdownView(
                value,
                isComplete: presentationComplete,
                streamID: TranscriptStreamingTextIdentity.mainResponseSegment(
                  turnID: turnID,
                  entryID: entryID,
                  segmentIndex: index
                ),
                animationPresentation: animationPresentation,
                animationCoordinator: animationCoordinator,
                animationEnabled: presentsAnimation
              )
            }
          case let .file(file, label):
            attachmentContent(file, label)
              .transition(
                entrance.revealingSegmentIndex == index
                  ? .opacity
                  : .identity
              )
          }
        }
      }
    }
    .preference(
      key: StreamingMarkdownEntranceAnimationPreferenceKey.self,
      value: animationCoordinator.hasActiveEntranceAnimation
        || entrance.hasActiveEntrance
    )
    .task(id: mount.activationToken) {
      guard mount.needsActivation else { return }
      await Task.yield()
      if animationMount.activate(token: mount.activationToken) {
        animationMountRevision &+= 1
      }
    }
    .task(id: presentationWork) {
      await perform(presentationWork)
    }
    .onChange(of: isGenerating, initial: true) { _, generating in
      if presentationState.observeProvider(isGenerating: generating) {
        if generating { animationCoordinator.reset() }
        presentationRevision &+= 1
      }
    }
    .onChange(of: reduceMotion) { _, reduced in
      if reduced { animationCoordinator.reset() }
    }
    .onChange(of: animationEnabled) { _, enabled in
      if !enabled { animationCoordinator.reset() }
    }
  }

  private func perform(_ work: StreamingAssistantResponsePresentationWork) async {
    do {
      switch work {
      case .idle:
        return
      case let .revealFile(fileID):
        // A response-level attachment must also wait for structural
        // entrances inside the preceding Markdown slice.
        try await animationCoordinator.waitUntilFullyIdle()
        switch entranceSequence.beginReveal(fileID: fileID) {
        case .started:
          animationCoordinator.scheduleElementEntrance()
          withAnimation(StreamingContentAnimationCoordinator.elementEntranceAnimation) {
            entranceRevision &+= 1
          }
        case .resumed:
          break
        case .unavailable:
          return
        }

        try await animationCoordinator.waitUntilIdle()
        guard entranceSequence.finishReveal(fileID: fileID) else { return }
        entranceRevision &+= 1
      case .finishPresentation:
        // Provider completion freezes the input, but the streaming
        // renderer remains mounted until all reserved visual work has
        // drained. Only this transition enables the finalized merge.
        try await animationCoordinator.waitUntilFullyIdle()
        guard presentationState.finishPresentation() else { return }
        presentationRevision &+= 1
      }
    } catch is CancellationError {
      return
    } catch {
      return
    }
  }
}

enum StreamingAssistantResponsePresentationWork: Hashable {
  case idle
  case revealFile(String)
  case finishPresentation
}

@MainActor
final class StreamingAssistantResponsePresentationState {
  enum Phase: Equatable {
    case receiving
    case draining
    case complete
  }

  private(set) var phase: Phase

  init(providerIsGenerating: Bool) {
    phase = providerIsGenerating ? .receiving : .complete
  }

  var isComplete: Bool { phase == .complete }

  @discardableResult
  func observeProvider(isGenerating: Bool) -> Bool {
    let nextPhase: Phase
    if isGenerating {
      nextPhase = .receiving
    } else if phase == .receiving {
      nextPhase = .draining
    } else {
      nextPhase = phase
    }
    guard nextPhase != phase else { return false }
    phase = nextPhase
    return true
  }

  func nextWork(pendingFileID: String?) -> StreamingAssistantResponsePresentationWork {
    guard phase != .complete else { return .idle }
    if let pendingFileID { return .revealFile(pendingFileID) }
    return phase == .draining ? .finishPresentation : .idle
  }

  @discardableResult
  func finishPresentation() -> Bool {
    guard phase == .draining else { return false }
    phase = .complete
    return true
  }
}

@MainActor
private final class StreamingAssistantResponseAnimationMount {
  struct Resolution {
    let animatesInitialContent: Bool
    let activationToken: Int
    let needsActivation: Bool
  }

  private var streamID: String?
  private var presentationID: ObjectIdentifier?
  private var settlementToken: Int?
  private var isBaselining = false
  private var activationToken = 0

  func resolve(
    streamID: String,
    presentation: StreamingTextAnimationPresentation
  ) -> Resolution {
    let nextPresentationID = ObjectIdentifier(presentation)
    let nextSettlementToken = presentation.settlementToken(for: streamID)
    if self.streamID != streamID || presentationID != nextPresentationID {
      self.streamID = streamID
      presentationID = nextPresentationID
      settlementToken = nextSettlementToken
      isBaselining =
        nextSettlementToken != nil
        || !presentation.claimInitialAnimation(for: streamID)
      if isBaselining { activationToken &+= 1 }
    } else if settlementToken != nextSettlementToken {
      settlementToken = nextSettlementToken
      isBaselining = nextSettlementToken != nil
      if isBaselining { activationToken &+= 1 }
    }
    return Resolution(
      animatesInitialContent: !isBaselining,
      activationToken: activationToken,
      needsActivation: isBaselining
    )
  }

  func activate(token: Int) -> Bool {
    guard isBaselining, token == activationToken else { return false }
    isBaselining = false
    return true
  }
}

@MainActor
final class StreamingAssistantResponseEntranceSequence {
  enum BeginRevealResult: Equatable {
    case started
    case resumed
    case unavailable
  }

  struct Resolution: Equatable {
    let visibleSegmentCount: Int
    let pendingFileID: String?
    let revealingSegmentIndex: Int?

    var hasActiveEntrance: Bool { pendingFileID != nil }
  }

  private struct FilePosition {
    let id: String
    let segmentIndex: Int
  }

  private var revealedFileIDs: Set<String> = []
  private var revealingFileID: String?

  func resolve(
    segments: [AssistantMarkdownSegment],
    responseStreamID: String,
    animationEnabled: Bool,
    animatesInitialContent: Bool,
    reduceMotion: Bool
  ) -> Resolution {
    let files = Self.filePositions(in: segments, responseStreamID: responseStreamID)
    let currentFileIDs = Set(files.map(\.id))

    if let revealingFileID, !currentFileIDs.contains(revealingFileID) {
      self.revealingFileID = nil
    }

    guard animationEnabled, animatesInitialContent, !reduceMotion else {
      revealedFileIDs.formUnion(currentFileIDs)
      revealingFileID = nil
      return Resolution(
        visibleSegmentCount: segments.count,
        pendingFileID: nil,
        revealingSegmentIndex: nil
      )
    }

    guard let pending = files.first(where: { !revealedFileIDs.contains($0.id) }) else {
      return Resolution(
        visibleSegmentCount: segments.count,
        pendingFileID: nil,
        revealingSegmentIndex: nil
      )
    }

    if let revealingFileID, revealingFileID != pending.id {
      self.revealingFileID = nil
    }
    let isRevealing = self.revealingFileID == pending.id
    return Resolution(
      visibleSegmentCount: pending.segmentIndex + (isRevealing ? 1 : 0),
      pendingFileID: pending.id,
      revealingSegmentIndex: isRevealing ? pending.segmentIndex : nil
    )
  }

  func beginReveal(fileID: String) -> BeginRevealResult {
    guard !revealedFileIDs.contains(fileID) else { return .unavailable }
    if revealingFileID == fileID { return .resumed }
    guard revealingFileID == nil else { return .unavailable }
    revealingFileID = fileID
    return .started
  }

  func finishReveal(fileID: String) -> Bool {
    guard revealingFileID == fileID else { return false }
    revealedFileIDs.insert(fileID)
    revealingFileID = nil
    return true
  }

  private static func filePositions(
    in segments: [AssistantMarkdownSegment],
    responseStreamID: String
  ) -> [FilePosition] {
    segments.enumerated().compactMap { index, segment in
      guard case let .file(file, _) = segment else { return nil }
      return FilePosition(
        id: "\(responseStreamID).\(index).file.\(file.id)",
        segmentIndex: index
      )
    }
  }
}
