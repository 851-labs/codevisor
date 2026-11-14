import Foundation
import Testing

@testable import CodevisorCore

struct NavigationPresentationTests {
  typealias Machine = NavigationPresentation.Machine

  static func machine(cached: Bool = false, empty: Bool = true, state: NavigationSyncState = .catchingUp) -> Machine {
    Machine(hasCache: cached, cacheIsEmpty: empty, syncState: state)
  }

  @Test("Cached content shows immediately, whatever the machines are doing")
  func contentFirst() {
    let machines = [Self.machine(cached: true, empty: false, state: .cached)]
    #expect(NavigationPresentation.launch(machines: machines, roster: .unverified, hasVisibleContent: true) == .content)
  }

  @Test("A spinner only while nothing is cached and a machine is still being reached")
  func spinnerOnlyWithoutCache() {
    let machines = [Self.machine(state: .catchingUp)]
    #expect(NavigationPresentation.launch(machines: machines, roster: .verified, hasVisibleContent: false) == .loading)
  }

  @Test("No Workspaces only once every machine has answered empty")
  func emptyWhenCertain() {
    let answered = [
      Self.machine(cached: true, state: .current), Self.machine(cached: true, state: .current),
    ]
    #expect(NavigationPresentation.launch(machines: answered, roster: .verified, hasVisibleContent: false) == .empty)
    let stillCatchingUp = [Self.machine(cached: true, state: .current), Self.machine(state: .catchingUp)]
    #expect(
      NavigationPresentation.launch(machines: stillCatchingUp, roster: .verified, hasVisibleContent: false) == .loading)
    let oneHasContent = [
      Self.machine(cached: true, empty: false, state: .current),
      Self.machine(cached: true, state: .current),
    ]
    #expect(
      NavigationPresentation.launch(machines: oneHasContent, roster: .verified, hasVisibleContent: false) == .empty)
  }

  @Test("Unreachable machines end the wait instead of spinning forever")
  func unreachableEndsWait() {
    let machines = [Self.machine(state: .stale("offline"))]
    #expect(NavigationPresentation.launch(machines: machines, roster: .verified, hasVisibleContent: false) == .empty)
  }

  @Test("With no machines, onboarding -- unless a cached machine list is still being confirmed")
  func noMachines() {
    #expect(NavigationPresentation.launch(machines: [], roster: .none, hasVisibleContent: false) == .onboarding)
    #expect(NavigationPresentation.launch(machines: [], roster: .verified, hasVisibleContent: false) == .onboarding)
    #expect(NavigationPresentation.launch(machines: [], roster: .unverified, hasVisibleContent: false) == .loading)
  }

  @Test("The indicator says syncing while machines catch up, and stays quiet for ones it can't reach")
  func indicator() {
    let syncing = NavigationPresentation.indicator(machines: [Self.machine(cached: true, state: .cached)])
    #expect(syncing.isSyncing)
    #expect(syncing.label == "Syncing…")
    let quiet = NavigationPresentation.indicator(machines: [Self.machine(state: .current)])
    #expect(!quiet.isSyncing)
    #expect(quiet.label == nil)
    let offline = NavigationPresentation.indicator(machines: [
      Self.machine(state: .current), Self.machine(state: .stale("down")),
    ])
    #expect(!offline.isSyncing)
    #expect(offline.label == nil)
    let catchingUpBesideOffline = NavigationPresentation.indicator(machines: [
      Self.machine(state: .catchingUp), Self.machine(state: .stale("down")),
    ])
    #expect(catchingUpBesideOffline.label == "Syncing…")
  }

  @Test("With nothing on screen yet, the launch spinner is the only loading state")
  func indicatorNeedsVisibleContent() {
    let catchingUp = [Self.machine(state: .catchingUp)]
    #expect(!NavigationPresentation.indicator(machines: catchingUp, hasVisibleContent: false).isSyncing)
    #expect(NavigationPresentation.indicator(machines: catchingUp, hasVisibleContent: true).isSyncing)
  }
}
