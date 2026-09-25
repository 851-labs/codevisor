import CodevisorCore
import QuartzCore
import SwiftUI
import TranscriptKit

/// What a native virtualizer exposes to its send transitions.
@MainActor
public protocol TranscriptSendTransitionAdapter: AnyObject {
  associatedtype Host: TranscriptSendPlatformView

  var sendTransitionMountedHosts: [String: Host] { get }
  var sendTransitionViewportHeight: CGFloat { get }
  func sendTransitionRowIndex(for key: String) -> Int?
  /// The host's top edge in window coordinates (top-left origin).
  func sendTransitionScreenY(of host: Host) -> CGFloat
  /// The host has laid out its current content.
  func sendTransitionIsReady(_ host: Host) -> Bool
  /// The row's content at its transcript width, for the flight's copy.
  func sendTransitionRowContent(for key: String) -> AnyView?
  /// How far below its slot a row starts when it lifts in without a
  /// composer snapshot (positive is down).
  func sendTransitionLiftOffset(for host: Host) -> CGFloat
  /// A send is about to present into this surface. A brand-new chat's
  /// transcript has never been revealed (its first content is this very
  /// row), so it opens its initial presentation gate here rather than
  /// waiting for a harness reply while the flight plays unseen.
  func sendTransitionWillPresent()
}

/// Every send presentation of one transcript surface.
///
/// The model is optimistic end to end: the row is published on the tap, and
/// nothing here waits on the server. A send only needs its row to be laid
/// out; from then on everything is render-server animation:
///
/// - the composer's glyphs fly into the row (or, with no snapshot, the row
///   lifts in from the composer's edge);
/// - every layout change the transcript makes while the send is live (the
///   new row making room, a status row arriving, a corrected height) is
///   applied at once to the model and animated with an additive spring, so
///   there is nothing to hold, defer, or reconcile afterwards;
/// - rows that arrive below the bubble fade in as it lands.
@MainActor
public final class TranscriptSendTransitions<Adapter: TranscriptSendTransitionAdapter> {
  public typealias Host = Adapter.Host

  private enum Phase {
    case awaitingRow
    case awaitingFlight(mountedAt: CFTimeInterval)
    case flying(TranscriptSendFlight)
    case lifting
    case landed
  }

  private struct Entry {
    let request: UserSendAnimationRequest
    let rowKey: String
    let startedAt: CFTimeInterval
    var phase: Phase
    var isClaimed = false
    var didNotifyStart = false
    var didNotifyCompletion = false

    var isLanded: Bool {
      if case .landed = phase { return true }
      return false
    }

    /// The real row is hidden under a flying copy; the copy follows it.
    var hidesRow: Bool {
      switch phase {
      case .awaitingFlight, .flying: true
      case .awaitingRow, .lifting, .landed: false
      }
    }
  }

  public weak var adapter: Adapter?
  public var session: ObjectIdentifier?
  public var reduceMotion = false
  public var claim: (@MainActor (UserSendAnimationRequest) -> Bool)?
  public var onStarted: (@MainActor (UserSendAnimationRequest) -> Void)?
  public var onCompleted: (@MainActor (UserSendAnimationRequest) -> Void)?

  private var entries: [Entry] = []
  private var receivedToken: UInt64?
  private var shifts: [(shift: TranscriptSendShift, members: Int)] = []
  private var shiftSerial: UInt64 = 0
  private var shiftDepth = 0
  private var advanceScheduled = false
  private var isStartingFlights = false

  public init() {}

  // MARK: Requests

  /// A new send from this surface's controller. Non-foreground surfaces (a
  /// route prewarming under New Chat's sheet) show the landed row as-is.
  public func receive(_ request: UserSendAnimationRequest?, isForeground: Bool) {
    guard request?.token != receivedToken else { return }
    receivedToken = request?.token
    guard let request, isForeground else { return }
    let rowKey = TranscriptVirtualRow.ID.message(request.messageID).layoutKey
    entries.append(
      Entry(request: request, rowKey: rowKey, startedAt: CACurrentMediaTime(), phase: .awaitingRow))
    if reduceMotion {
      if let session { TranscriptSendStaging.shared.cancel(session: session) }
      finish(index: entries.count - 1, claimIfNeeded: true)
      return
    }
    if let host = adapter?.sendTransitionMountedHosts[rowKey] {
      hostDidMount(host, key: rowKey)
    }
    scheduleAdvance(after: TranscriptSendMotion.transitionWindow)
  }

  public var isLive: Bool {
    let now = CACurrentMediaTime()
    return entries.contains { entry in
      if case .landed = entry.phase {
        return now - entry.startedAt < TranscriptSendMotion.transitionWindow
      }
      return true
    }
  }

  /// Rows are presented away from their model frames (a running shift or
  /// flight). The virtualizer keeps their hosts mounted until this clears,
  /// so a row sliding through the viewport is never retired mid-motion.
  public var isAnimatingRows: Bool {
    let now = CACurrentMediaTime()
    return shifts.contains { $0.shift.isRunning(at: now) } || entries.contains { !$0.isLanded }
  }

  // MARK: Mounting

  /// Called for every host the virtualizer mounts (after positioning).
  public func hostDidMount(_ host: Host, key: String) {
    guard !entries.isEmpty else { return }
    if let index = entries.lastIndex(where: { $0.rowKey == key }) {
      destinationDidMount(host, entryIndex: index)
      return
    }
    guard isLive, let layer = host.transcriptSendLayer else { return }
    let now = CACurrentMediaTime()
    if let latest = entries.last(where: { !$0.isLanded || now - $0.startedAt < TranscriptSendMotion.transitionWindow }),
      let rowIndex = adapter?.sendTransitionRowIndex(for: key),
      let sendIndex = adapter?.sendTransitionRowIndex(for: latest.rowKey),
      rowIndex > sendIndex
    {
      // Arrived under the bubble: appear as it lands, never under it.
      let revealAt = max(now, latest.startedAt + TranscriptSendMotion.followerRevealDelay)
      layer.add(
        TranscriptSendLayerAnimations.fade(
          from: 0, to: 1, duration: TranscriptSendMotion.followerFadeDuration, beginTime: revealAt),
        forKey: TranscriptSendAnimationKeys.follower)
      return
    }
    // History mounted mid-shift joins the movement already under way.
    if let running = shifts.filter({ $0.shift.isRunning(at: now) }).max(by: { $0.members < $1.members }) {
      TranscriptSendLayerAnimations.replay(running.shift, on: layer)
    }
  }

  private func destinationDidMount(_ host: Host, entryIndex index: Int) {
    transcriptSendLog.debug(
      "destination mounted: layer=\(host.transcriptSendLayer != nil) staged=\(self.session.map { TranscriptSendStaging.shared.hasStage(for: $0) } ?? false)"
    )
    guard let layer = host.transcriptSendLayer else { return }
    switch entries[index].phase {
    case .awaitingRow:
      if let session, TranscriptSendStaging.shared.hasStage(for: session) {
        layer.add(
          TranscriptSendLayerAnimations.hide(duration: TranscriptSendMotion.targetHoldLimit),
          forKey: TranscriptSendAnimationKeys.hide)
        entries[index].phase = .awaitingFlight(mountedAt: CACurrentMediaTime())
        // Mounting can happen inside SwiftUI's update; the flight renders
        // a copy of the row, so start it once that update has returned.
        scheduleAdvance()
        scheduleAdvance(after: 0.12)
      } else {
        lift(host, entryIndex: index)
      }
    case .awaitingFlight:
      layer.add(
        TranscriptSendLayerAnimations.hide(duration: TranscriptSendMotion.targetHoldLimit),
        forKey: TranscriptSendAnimationKeys.hide)
    case let .flying(flight):
      layer.add(
        TranscriptSendLayerAnimations.hide(duration: TranscriptSendFlight.duration + 0.5),
        forKey: TranscriptSendAnimationKeys.hide)
      flight.follow(host)
    case .lifting, .landed:
      break
    }
  }

  // MARK: Layout

  /// Wraps a model change that can move rows (applying a projection,
  /// committing heights). Rows that moved get an additive spring from their
  /// previous on-screen position; user scrolling and viewport resizes are
  /// never wrapped, so they keep their native motion.
  public func animatingContentShift(_ body: () -> Void) {
    let capture = beginContentShift()
    body()
    commitContentShift(capture)
  }

  /// Screen positions captured before a model change; see
  /// `animatingContentShift`. Nil when no send is live or already inside
  /// an outer capture.
  public struct ContentShiftCapture {
    fileprivate let screenYByKey: [String: CGFloat]
  }

  public func beginContentShift() -> ContentShiftCapture? {
    guard shiftDepth == 0, isLive, let adapter else {
      shiftDepth += 1
      return nil
    }
    shiftDepth += 1
    return ContentShiftCapture(
      screenYByKey: adapter.sendTransitionMountedHosts.mapValues { adapter.sendTransitionScreenY(of: $0) })
  }

  public func commitContentShift(_ capture: ContentShiftCapture?) {
    shiftDepth = max(0, shiftDepth - 1)
    guard let capture, let adapter else { return }
    let before = capture.screenYByKey

    var groups: [Int: (offset: CGFloat, hosts: [Host])] = [:]
    let limit = adapter.sendTransitionViewportHeight * 1.5
    for (key, host) in adapter.sendTransitionMountedHosts {
      guard let previous = before[key],
        !entries.contains(where: { $0.rowKey == key && $0.hidesRow })
      else { continue }
      let offset = previous - adapter.sendTransitionScreenY(of: host)
      // Large moves are scroll jumps (a send from far up the history):
      // those rows are about to leave the screen anyway.
      guard abs(offset) > 0.5, abs(offset) < limit else { continue }
      let bucket = Int((offset * 2).rounded())
      groups[bucket, default: (offset, [])].hosts.append(host)
    }
    guard !groups.isEmpty else {
      advance()
      return
    }
    let now = CACurrentMediaTime()
    shifts.removeAll { !$0.shift.isRunning(at: now) }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for group in groups.values {
      shiftSerial &+= 1
      let shift = TranscriptSendShift(offset: group.offset, beginTime: now, serial: shiftSerial)
      shifts.append((shift, group.hosts.count))
      for host in group.hosts {
        guard let layer = host.transcriptSendLayer else { continue }
        TranscriptSendLayerAnimations.replay(shift, on: layer)
      }
    }
    CATransaction.commit()
    advance()
  }

  /// Starts flights whose destination is ready and keeps running flights
  /// aimed at their rows. Cheap; call after any layout or measurement pass.
  public func advance() {
    guard !entries.isEmpty, let adapter else { return }
    let now = CACurrentMediaTime()
    for index in entries.indices {
      switch entries[index].phase {
      case .awaitingRow:
        if now - entries[index].startedAt > TranscriptSendMotion.transitionWindow {
          // The row never arrived (the send failed before publishing it).
          finish(index: index, claimIfNeeded: true)
        }
      case let .awaitingFlight(mountedAt):
        guard let host = adapter.sendTransitionMountedHosts[entries[index].rowKey] else { continue }
        guard adapter.sendTransitionIsReady(host) || now - mountedAt > 0.1 else { continue }
        // `advance` can run inside SwiftUI's update of the transcript; the
        // flight renders a copy of the row in its own hosting view, so it
        // always starts on the next main-queue turn. The staged glyphs
        // hold the composer's text in place for that frame.
        guard isStartingFlights else {
          scheduleAdvance()
          continue
        }
        beginFlight(into: host, entryIndex: index)
      case let .flying(flight):
        if let host = adapter.sendTransitionMountedHosts[entries[index].rowKey] {
          flight.follow(host)
        } else {
          transcriptSendLog.debug("flight target unmounted; landing")
          flight.land()
        }
      case .lifting, .landed:
        break
      }
    }
    entries.removeAll { entry in
      entry.isLanded && now - entry.startedAt >= TranscriptSendMotion.transitionWindow
    }
  }

  // MARK: Presentation

  private func beginFlight(into host: Host, entryIndex index: Int) {
    let entry = entries[index]
    guard let session, let adapter, let layer = host.transcriptSendLayer else { return }
    adapter.sendTransitionWillPresent()
    guard claimOnce(index: index) else {
      layer.removeAnimation(forKey: TranscriptSendAnimationKeys.hide)
      TranscriptSendStaging.shared.cancel(session: session)
      finish(index: index, claimIfNeeded: false)
      return
    }
    let token = entry.request.token
    guard let content = adapter.sendTransitionRowContent(for: entry.rowKey),
      let flight = TranscriptSendFlight.begin(
        session: session,
        rowContent: content,
        target: host,
        completion: { [weak self] in self?.flightDidLand(token: token) }
      )
    else {
      transcriptSendLog.debug("flight could not begin; lifting")
      TranscriptSendStaging.shared.cancel(session: session)
      layer.removeAnimation(forKey: TranscriptSendAnimationKeys.hide)
      lift(host, entryIndex: index)
      return
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.add(
      TranscriptSendLayerAnimations.hide(duration: TranscriptSendFlight.duration + 0.5),
      forKey: TranscriptSendAnimationKeys.hide)
    CATransaction.commit()
    entries[index].phase = .flying(flight)
    transcriptSendLog.debug("flight began")
    notifyStart(index: index)
  }

  private func flightDidLand(token: UInt64) {
    guard let index = entries.firstIndex(where: { $0.request.token == token }) else { return }
    // Same transaction as the flight's removal: row and copy swap exactly.
    if let host = adapter?.sendTransitionMountedHosts[entries[index].rowKey] {
      host.transcriptSendLayer?.removeAnimation(forKey: TranscriptSendAnimationKeys.hide)
    }
    finish(index: index, claimIfNeeded: false)
  }

  /// The row itself rises from the composer's edge and fades in. Used when
  /// there is no composer snapshot (a queued prompt promoted into the
  /// transcript, a send from another surface).
  private func lift(_ host: Host, entryIndex index: Int) {
    guard claimOnce(index: index), let adapter, let layer = host.transcriptSendLayer else {
      finish(index: index, claimIfNeeded: false)
      return
    }
    adapter.sendTransitionWillPresent()
    let offset = adapter.sendTransitionLiftOffset(for: host)
    transcriptSendLog.debug("lift offset=\(Double(offset))")
    guard offset > 1 else {
      finish(index: index, claimIfNeeded: false)
      return
    }
    let token = entries[index].request.token
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let move = TranscriptSendLayerAnimations.verticalShift(offset)
    move.stiffness = TranscriptSendMotion.bubble.stiffness
    move.damping = TranscriptSendMotion.bubble.damping
    move.duration = TranscriptSendMotion.bubble.settlingDuration()
    move.delegate = TranscriptSendAnimationCompletion { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, let index = self.entries.firstIndex(where: { $0.request.token == token }) else { return }
        self.finish(index: index, claimIfNeeded: false)
      }
    }
    layer.add(move, forKey: TranscriptSendAnimationKeys.lift)
    layer.add(
      TranscriptSendLayerAnimations.fade(from: 0, to: 1, duration: TranscriptSendMotion.crossfadeDuration),
      forKey: TranscriptSendAnimationKeys.follower)
    CATransaction.commit()
    entries[index].phase = .lifting
    notifyStart(index: index)
  }

  /// Leaving the foreground or detaching: land every flight at once and
  /// reveal everything. Sends this surface never claimed are left alone,
  /// staged glyphs included: SwiftUI can replace a transcript surface
  /// mid-send (a new chat's first screen is built as the send happens),
  /// and the replacement presents them.
  public func interrupt() {
    landFlights()
    if let adapter {
      for index in entries.indices where entries[index].isClaimed {
        adapter.sendTransitionMountedHosts[entries[index].rowKey]?.transcriptSendLayer?
          .removeAnimation(forKey: TranscriptSendAnimationKeys.hide)
        finish(index: index, claimIfNeeded: false)
      }
    }
    entries.removeAll()
    shifts.removeAll()
    // A reattached surface receives the same request again.
    receivedToken = nil
  }

  /// Lands flights already in the air (the layout is being rebuilt under
  /// them); sends still waiting for their row are unaffected.
  public func landFlights() {
    for entry in entries {
      if case let .flying(flight) = entry.phase { flight.land() }
    }
  }

  // MARK: Bookkeeping

  private func claimOnce(index: Int) -> Bool {
    if entries[index].isClaimed { return true }
    guard claim?(entries[index].request) ?? true else { return false }
    entries[index].isClaimed = true
    return true
  }

  private func notifyStart(index: Int) {
    guard !entries[index].didNotifyStart else { return }
    entries[index].didNotifyStart = true
    onStarted?(entries[index].request)
  }

  private func finish(index: Int, claimIfNeeded: Bool) {
    guard entries.indices.contains(index) else { return }
    if claimIfNeeded, !entries[index].isClaimed {
      _ = claim?(entries[index].request)
      entries[index].isClaimed = true
    }
    entries[index].phase = .landed
    guard !entries[index].didNotifyCompletion else { return }
    entries[index].didNotifyCompletion = true
    let request = entries[index].request
    notifyStart(index: index)
    onCompleted?(request)
  }

  private func scheduleAdvance(after delay: TimeInterval? = nil) {
    if let delay {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        self?.startReadyFlights()
      }
      return
    }
    guard !advanceScheduled else { return }
    advanceScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      advanceScheduled = false
      startReadyFlights()
    }
  }

  /// `advance`, also starting flights whose rows are ready. Only for a
  /// caller on a main-queue turn of its own, outside any view update.
  public func startReadyFlights() {
    isStartingFlights = true
    defer { isStartingFlights = false }
    advance()
  }
}
