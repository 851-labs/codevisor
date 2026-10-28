import ACPKit
import Foundation
import Observation

@MainActor
@Observable
final class BotSendQueue {
  enum Readiness: Equatable {
    case ready
    case waiting(String)
    case failed(String)
  }

  enum Preparation {
    case ready(SessionModel)
    case failed(String)
  }

  static let readinessTimeout: Duration = .seconds(60)
  static let progressDelay: Duration = .seconds(1)

  private enum Stage: Equatable {
    case preparing
    case handedOff
    case failed(String)
  }

  private enum UploadOutcome {
    case uploaded([Attachment])
    case withdrawn
    case failed(String)
  }

  private struct Entry {
    let message: UserMessage
    let attachmentIDs: [UUID]
    let afterSequence: Int?
    var stage = Stage.preparing
    var showsProgress = false

    var delivery: TranscriptDelivery? {
      if case let .failed(reason) = stage { return .failed(reason: reason) }
      return showsProgress ? .sending : nil
    }
  }

  private var entries: [Entry] = [] { didSet { onChange() } }
  @ObservationIgnored private var worker: Task<Void, Never>?
  @ObservationIgnored private let attachments: ComposerAttachments
  @ObservationIgnored private let clock: any Clock<Duration>
  @ObservationIgnored private let readiness: @MainActor () -> Readiness
  @ObservationIgnored private let connect: @MainActor (UserMessage) async -> Preparation
  @ObservationIgnored private let onUploaded: (_ uploaded: Attachment, _ sentFileID: String) -> Void
  @ObservationIgnored private let onChange: () -> Void

  init(
    attachments: ComposerAttachments,
    clock: any Clock<Duration> = ContinuousClock(),
    readiness: @escaping @MainActor () -> Readiness,
    connect: @escaping @MainActor (UserMessage) async -> Preparation,
    onUploaded: @escaping (_ uploaded: Attachment, _ sentFileID: String) -> Void,
    onChange: @escaping () -> Void
  ) {
    self.attachments = attachments
    self.clock = clock
    self.readiness = readiness
    self.connect = connect
    self.onUploaded = onUploaded
    self.onChange = onChange
  }

  func enqueue(_ message: UserMessage, attachmentIDs: [UUID], afterSequence: Int?) {
    entries.append(Entry(message: message, attachmentIDs: attachmentIDs, afterSequence: afterSequence))
    showProgress(for: message.id, after: Self.progressDelay)
    startWorker()
  }

  func holdsFailure(_ id: UUID) -> Bool {
    guard let index = index(of: id), case .failed = entries[index].stage else { return false }
    return true
  }

  func retry(_ id: UUID) {
    guard holdsFailure(id), let index = index(of: id) else { return }

    for attachmentID in entries[index].attachmentIDs { attachments.retryAttachment(id: attachmentID) }
    entries[index].stage = .preparing
    entries[index].showsProgress = true
    startWorker()
  }

  func delete(_ id: UUID) {
    guard holdsFailure(id), let index = index(of: id) else { return }

    let entry = entries.remove(at: index)
    attachments.releaseSent(entry.attachmentIDs)
  }

  var unsentMessages: [UnsentBotMessage] {
    entries.map { entry in
      UnsentBotMessage(
        message: TranscriptBotMessage(
          id: entry.message.id.uuidString.lowercased(), sender: .user, text: entry.message.text,
          attachments: entry.message.attachments, delivery: entry.delivery),
        afterSequence: entry.afterSequence)
    }
  }

  private func startWorker() {
    guard worker == nil else { return }

    worker = Task { [weak self] in
      await self?.drain()
      self?.worker = nil
    }
  }

  private func drain() async {
    while let message = entries.first(where: { $0.stage == .preparing })?.message {
      await send(message)
    }
  }

  private func send(_ message: UserMessage) async {
    switch await preparedModel(for: message) {
    case let .ready(model): await send(message.id, through: model)
    case let .failed(reason): failPreparing(reason)
    }
  }

  private func preparedModel(for message: UserMessage) async -> Preparation {
    if let failure = await readinessFailure() { return .failed(failure) }
    return await connect(message)
  }

  private func readinessFailure() async -> String? {
    let deadline = ReadinessDeadline()
    let timer = Task { [clock] in
      guard (try? await clock.sleep(for: Self.readinessTimeout)) != nil else { return }
      deadline.hasPassed = true
    }
    defer { timer.cancel() }

    let outcome = await ObservedState.first { Self.settled(readiness(), deadline: deadline) }
    guard case let .failed(reason)? = outcome else { return nil }
    return reason
  }

  private func send(_ id: UUID, through model: SessionModel) async {
    switch await ObservedState.first({ uploadOutcome(for: id) }) {
    case let .uploaded(uploaded)?: handOff(id, attachments: uploaded, to: model)
    case let .failed(reason)?: fail(id, reason)
    case .withdrawn?, nil: return
    }
  }

  private func handOff(_ id: UUID, attachments uploaded: [Attachment], to model: SessionModel) {
    guard let index = index(of: id) else { return }

    let entry = entries[index]
    zip(entry.message.attachments, uploaded).forEach { onUploaded($1, $0.fileId) }
    entries[index].stage = .handedOff
    let message = UserMessage(id: id, text: entry.message.text, attachments: uploaded)
    let anchor = entry.afterSequence ?? model.botMessages.last?.sequence
    Task { [weak self] in
      await model.sendBotMessage(message, afterSequence: anchor)
      self?.finish(id)
    }
  }

  private func finish(_ id: UUID) {
    guard let index = index(of: id) else { return }

    let entry = entries.remove(at: index)
    attachments.releaseSent(entry.attachmentIDs)
  }

  private func fail(_ id: UUID, _ reason: String) {
    guard let index = index(of: id) else { return }
    entries[index].stage = .failed(reason)
  }

  private func failPreparing(_ reason: String) {
    for index in entries.indices where entries[index].stage == .preparing {
      entries[index].stage = .failed(reason)
    }
  }

  private func showProgress(for id: UUID, after delay: Duration) {
    Task { [weak self, clock] in
      guard (try? await clock.sleep(for: delay)) != nil else { return }
      guard let self, let index = self.index(of: id) else { return }
      self.entries[index].showsProgress = true
    }
  }

  private func index(of id: UUID) -> Int? {
    entries.firstIndex { $0.message.id == id }
  }

  private func uploadOutcome(for id: UUID) -> UploadOutcome? {
    guard let entry = entries.first(where: { $0.message.id == id }) else { return .withdrawn }
    return Self.uploadOutcome(of: attachments.sentAttachments(entry.attachmentIDs), expected: entry.attachmentIDs)
  }

  private static func settled(_ readiness: Readiness, deadline: ReadinessDeadline) -> Readiness? {
    switch readiness {
    case .ready, .failed: readiness
    case let .waiting(reason): deadline.hasPassed ? .failed(reason) : nil
    }
  }

  private static func uploadOutcome(of sent: [ComposerAttachment], expected ids: [UUID]) -> UploadOutcome? {
    guard sent.count == ids.count else { return .failed("An attachment was removed before it was sent.") }
    if let failure = sent.lazy.compactMap(uploadFailure).first { return .failed(failure) }

    let uploaded = sent.compactMap { attachment -> Attachment? in
      guard case let .uploaded(ref) = attachment.state else { return nil }
      return ref.attachment
    }
    return uploaded.count == sent.count ? .uploaded(uploaded) : nil
  }

  private static func uploadFailure(of attachment: ComposerAttachment) -> String? {
    guard case let .failed(message) = attachment.state else { return nil }
    return "Couldn’t upload “\(attachment.name)”. \(message)"
  }
}

@MainActor
@Observable
private final class ReadinessDeadline {
  var hasPassed = false
}
