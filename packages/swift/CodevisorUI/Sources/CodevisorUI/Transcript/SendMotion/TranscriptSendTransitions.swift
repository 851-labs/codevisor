import CodevisorCore
import QuartzCore
import SwiftUI
import TranscriptKit

@MainActor
public protocol TranscriptSendTransitionAdapter: AnyObject {
  associatedtype Host: TranscriptSendPlatformView

  var sendTransitionMountedHosts: [String: Host] { get }
  var sendTransitionViewportHeight: CGFloat { get }
  func sendTransitionRowIndex(for key: String) -> Int?
  func sendTransitionScreenY(of host: Host) -> CGFloat
  func sendTransitionIsReady(_ host: Host) -> Bool
  func sendTransitionRowContent(for key: String) -> AnyView?
  func sendTransitionLiftOffset(for host: Host) -> CGFloat
  func sendTransitionWillPresent()
  var sendTransitionLanding: TranscriptSendLanding? { get }
  var sendTransitionPushDistance: CGFloat? { get }
  func sendTransitionCommitHeight(_ height: CGFloat, for key: String)
  func sendTransitionPinRowsToViewport()
}

extension TranscriptSendTransitionAdapter {
  public var sendTransitionLanding: TranscriptSendLanding? { nil }
  public var sendTransitionPushDistance: CGFloat? { nil }
  public func sendTransitionCommitHeight(_: CGFloat, for _: String) {}
  public func sendTransitionPinRowsToViewport() {}
}

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

    var hidesRow: Bool {
      switch phase {
      case .awaitingFlight, .flying: true
      case .awaitingRow, .lifting, .landed: false
      }
    }
  }

  public weak var adapter: Adapter?
  public var session: ObjectIdentifier? {
    didSet {
      #if canImport(UIKit)
        guard let session, session != oldValue else { return }
        TranscriptSendStaging.shared.setLandingProvider(
          for: session,
          owner: self,
          landing: { [weak self] in self?.adapter?.sendTransitionLanding },
          anticipate: { [weak self] beginTime in self?.anticipatePush(beginTime: beginTime) }
        )
      #endif
    }
  }
  public var reduceMotion = false
  public var largestAnimatedShift: CGFloat = 1.5
  public var claim: (@MainActor (UserSendAnimationRequest) -> Bool)?
  public var onStarted: (@MainActor (UserSendAnimationRequest) -> Void)?
  public var onCompleted: (@MainActor (UserSendAnimationRequest) -> Void)?

  private var entries: [Entry] = []
  private var receivedToken: UInt64?
  private var shifts: [(shift: TranscriptSendShift, members: Int)] = []
  private var shiftSerial: UInt64 = 0
  private var shiftDepth = 0
  private var push: (beginTime: CFTimeInterval, distance: CGFloat, base: CGFloat)?
  private var advanceScheduled = false
  private var isStartingFlights = false
  private var isSettlingFlightRow = false

  public init() {}

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

  public var isAnimatingRows: Bool {
    let now = layerTime
    return push != nil || shifts.contains { $0.shift.isRunning(at: now) } || entries.contains { !$0.isLanded }
  }

  public func hostDidMount(_ host: Host, key: String) {
    addPush(to: host)
    guard !entries.isEmpty else { return }
    if let index = entries.lastIndex(where: { $0.rowKey == key }) {
      destinationDidMount(host, entryIndex: index)
      return
    }
    guard isLive, let layer = host.transcriptSendLayer else { return }
    let now = CACurrentMediaTime()
    let clock = layer.convertTime(now, from: nil)
    if let latest = entries.last(where: { !$0.isLanded || now - $0.startedAt < TranscriptSendMotion.transitionWindow }),
      let rowIndex = adapter?.sendTransitionRowIndex(for: key),
      let sendIndex = adapter?.sendTransitionRowIndex(for: latest.rowKey),
      rowIndex > sendIndex
    {
      if let reveal = TranscriptSendLayerAnimations.followerReveal(
        sendStartedAt: latest.startedAt + clock - now, now: clock)
      {
        layer.add(reveal, forKey: TranscriptSendAnimationKeys.follower)
      }
      return
    }
    if let running = shifts.filter({ $0.shift.isRunning(at: clock) }).max(by: { $0.members < $1.members }) {
      TranscriptSendLayerAnimations.replay(running.shift, on: layer)
    }
  }

  private func destinationDidMount(_ host: Host, entryIndex index: Int) {
    transcriptSendLog.debug(
      "destination mounted: layer=\(host.transcriptSendLayer != nil) staged=\(self.session.map { TranscriptSendStaging.shared.hasStage(for: $0) } ?? false)"
    )
    guard let layer = host.transcriptSendLayer else { return }
    if TranscriptSendFlight.ridesTranscript,
      let running = shifts.filter({ $0.shift.isRunning(at: layer.convertTime(CACurrentMediaTime(), from: nil)) })
        .max(by: { $0.members < $1.members })
    {
      TranscriptSendLayerAnimations.replay(running.shift, on: layer)
    }
    switch entries[index].phase {
    case .awaitingRow:
      if let session, TranscriptSendStaging.shared.hasStage(for: session) {
        layer.add(
          TranscriptSendLayerAnimations.hide(duration: TranscriptSendMotion.targetHoldLimit),
          forKey: TranscriptSendAnimationKeys.hide)
        entries[index].phase = .awaitingFlight(mountedAt: CACurrentMediaTime())
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

  public func animatingContentShift(_ body: () -> Void) {
    let capture = beginContentShift()
    body()
    commitContentShift(capture)
  }

  public struct ContentShiftCapture {
    fileprivate let screenYByKey: [String: CGFloat]
  }

  public func beginContentShift() -> ContentShiftCapture? {
    guard shiftDepth == 0, isLive, let adapter else {
      shiftDepth += 1
      return nil
    }
    shiftDepth += 1
    if push != nil { adapter.sendTransitionPinRowsToViewport() }
    return ContentShiftCapture(
      screenYByKey: adapter.sendTransitionMountedHosts.mapValues { adapter.sendTransitionScreenY(of: $0) })
  }

  public func commitContentShift(_ capture: ContentShiftCapture?) {
    shiftDepth = max(0, shiftDepth - 1)
    guard let capture, let adapter else { return }
    let before = capture.screenYByKey
    let mounted = adapter.sendTransitionMountedHosts
    let now = layerTime
    let pushed = push.flatMap { push in
      entries.contains { mounted[$0.rowKey] != nil } ? push : nil
    }
    var lag: CGFloat = 0
    var spring = TranscriptSendMotion.content
    var beginTime = now
    var scale: CGFloat = 1
    if let pushed {
      push = nil
      spring = TranscriptSendMotion.bubble
      let remaining = CGFloat(spring.displacementFraction(at: now - pushed.beginTime))
      lag = pushed.base - pushed.distance * (1 - remaining)
      if remaining > 0.2 {
        beginTime = pushed.beginTime
        scale = 1 / remaining
      }
    }

    var groups: [Int: (offset: CGFloat, hosts: [Host])] = [:]
    var hiddenRows: [Host] = []
    let limit = pushed == nil ? adapter.sendTransitionViewportHeight * largestAnimatedShift : .infinity
    for (key, host) in mounted {
      if pushed != nil {
        host.transcriptSendLayer?.removeAnimation(forKey: TranscriptSendAnimationKeys.push)
      }
      if entries.contains(where: { $0.rowKey == key && $0.hidesRow }) {
        hiddenRows.append(host)
        continue
      }
      guard let previous = before[key] else { continue }
      let offset = (previous + lag - adapter.sendTransitionScreenY(of: host)) * scale
      guard abs(offset) > 0.5, abs(offset) < limit else { continue }
      let bucket = Int((offset * 2).rounded())
      groups[bucket, default: (offset, [])].hosts.append(host)
    }
    if TranscriptSendFlight.ridesTranscript,
      let lead = groups.max(by: { $0.value.hosts.count < $1.value.hosts.count })?.key
    {
      groups[lead]?.hosts.append(contentsOf: hiddenRows)
    }
    guard !groups.isEmpty else {
      advance()
      return
    }
    shifts.removeAll { !$0.shift.isRunning(at: now) }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for group in groups.values {
      shiftSerial &+= 1
      let shift = TranscriptSendShift(
        offset: group.offset, beginTime: beginTime, serial: shiftSerial, spring: spring)
      shifts.append((shift, group.hosts.count))
      for host in group.hosts {
        guard let layer = host.transcriptSendLayer else { continue }
        TranscriptSendLayerAnimations.replay(shift, on: layer)
      }
    }
    CATransaction.commit()
    advance()
  }

  public func advance() {
    guard !isSettlingFlightRow else { return }
    syncCarriers()
    if let push, layerTime - push.beginTime > TranscriptSendMotion.stagingTimeout {
      cancelPush()
    }
    guard !entries.isEmpty, let adapter else { return }
    let now = CACurrentMediaTime()
    for index in entries.indices {
      switch entries[index].phase {
      case .awaitingRow:
        if now - entries[index].startedAt > TranscriptSendMotion.transitionWindow {
          finish(index: index, claimIfNeeded: true)
        }
      case let .awaitingFlight(mountedAt):
        guard let host = adapter.sendTransitionMountedHosts[entries[index].rowKey] else { continue }
        guard adapter.sendTransitionIsReady(host) || now - mountedAt > 0.1 else { continue }
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

  private func syncCarriers() {
    guard TranscriptSendFlight.ridesTranscript else { return }
    if let session { TranscriptSendStaging.shared.syncCarrier(session: session) }
    for entry in entries {
      if case let .flying(flight) = entry.phase { flight.syncCarrier() }
    }
  }

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
        settleRowHeight: { [weak self] height in self?.settleFlightRow(height, for: entry.rowKey) },
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

  private func settleFlightRow(_ height: CGFloat, for key: String) {
    guard let adapter else { return }
    isSettlingFlightRow = true
    let capture = beginContentShift()
    adapter.sendTransitionCommitHeight(height, for: key)
    commitContentShift(capture)
    isSettlingFlightRow = false
  }

  private func flightDidLand(token: UInt64) {
    guard let index = entries.firstIndex(where: { $0.request.token == token }) else { return }
    if let host = adapter?.sendTransitionMountedHosts[entries[index].rowKey] {
      host.transcriptSendLayer?.removeAnimation(forKey: TranscriptSendAnimationKeys.hide)
    }
    finish(index: index, claimIfNeeded: false)
  }

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
    cancelPush()
    receivedToken = nil
  }

  public func landFlights() {
    for entry in entries {
      if case let .flying(flight) = entry.phase { flight.land() }
    }
  }

  public func startReadyFlights() {
    isStartingFlights = true
    defer { isStartingFlights = false }
    advance()
  }
}

extension TranscriptSendTransitions {
  private var layerTime: CFTimeInterval {
    let now = CACurrentMediaTime()
    guard let layer = adapter?.sendTransitionMountedHosts.values.first?.transcriptSendLayer else { return now }
    return layer.convertTime(now, from: nil)
  }

  func anticipatePush(beginTime: CFTimeInterval) {
    cancelPush()
    guard !reduceMotion, let adapter, let distance = adapter.sendTransitionPushDistance,
      distance > 0.5, distance < adapter.sendTransitionViewportHeight * largestAnimatedShift
    else { return }
    push = (beginTime, distance, 0)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for host in adapter.sendTransitionMountedHosts.values {
      addPush(to: host)
    }
    CATransaction.commit()
  }

  private func addPush(to host: Host) {
    guard let push, let layer = host.transcriptSendLayer else { return }
    layer.add(
      TranscriptSendLayerAnimations.push(push.distance, from: push.base, beginTime: push.beginTime),
      forKey: TranscriptSendAnimationKeys.push)
  }

  public var isPushing: Bool { push != nil }

  public func absorbViewportMove(_ distance: CGFloat) {
    guard push != nil, abs(distance) > 0.25, let adapter else { return }
    push?.base -= distance
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for host in adapter.sendTransitionMountedHosts.values {
      addPush(to: host)
    }
    CATransaction.commit()
  }

  private func cancelPush() {
    guard push != nil else { return }
    push = nil
    for host in adapter?.sendTransitionMountedHosts.values.map({ $0 }) ?? [] {
      host.transcriptSendLayer?.removeAnimation(forKey: TranscriptSendAnimationKeys.push)
    }
  }

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
}
