import Testing
@testable import CodevisorUI

@MainActor
struct DeferredPaneFocusTests {
  @MainActor private final class Scheduler {
    var actions: [@MainActor () -> Void] = []
    func run() {
      let ready = actions
      actions = []
      for action in ready { action() }
    }
  }

  @Test("A loading pane parks focus while navigation remains free to change")
  func loadingPaneDoesNotHoldNavigation() {
    let scheduler = Scheduler()
    let focus = DeferredPaneFocus(schedule: { scheduler.actions.append($0) })
    var selected = "chat"
    var attached = false
    var focused: [String] = []
    focus.request(isCurrent: { selected == "chat" }) {
      guard attached else { return false }
      focused.append("chat")
      return true
    }
    scheduler.run()
    #expect(focused.isEmpty)
    #expect(scheduler.actions.isEmpty)

    selected = "plugin"
    attached = true
    focus.retry()
    scheduler.run()
    #expect(selected == "plugin")
    #expect(focused.isEmpty)
    focus.retry()
    #expect(scheduler.actions.isEmpty)
  }

  @Test("Late callbacks cannot override the newest focus request", arguments: [false, true])
  func newestRequestWins(reverseCallbacks: Bool) {
    let scheduler = Scheduler()
    let focus = DeferredPaneFocus(schedule: { scheduler.actions.append($0) })
    var focused: [String] = []
    for destination in ["chat", "terminal", "browser", "plugin"] {
      focus.request(isCurrent: { true }) {
        focused.append(destination)
        return true
      }
    }
    if reverseCallbacks { scheduler.actions.reverse() }
    scheduler.run()
    #expect(focused == ["plugin"])
  }

  @Test("Native attachment retries only the outstanding request")
  func attachmentRetriesWithoutPolling() {
    let scheduler = Scheduler()
    let focus = DeferredPaneFocus(schedule: { scheduler.actions.append($0) })
    var attached = false
    var attempts = 0
    focus.request(isCurrent: { true }) {
      attempts += 1
      return attached
    }
    scheduler.run()
    #expect(attempts == 1)
    #expect(scheduler.actions.isEmpty)

    attached = true
    focus.retry()
    focus.retry()
    scheduler.run()
    #expect(attempts == 2)
    focus.retry()
    #expect(scheduler.actions.isEmpty)
  }

  @Test("Leaving the window cancels already queued focus")
  func cancellation() {
    let scheduler = Scheduler()
    let focus = DeferredPaneFocus(schedule: { scheduler.actions.append($0) })
    var focused = false
    focus.request(isCurrent: { true }) {
      focused = true
      return true
    }
    focus.cancel()
    scheduler.run()
    #expect(!focused)
  }

  @Test("A focus callback can enqueue its successor without losing it")
  func reentrantRequest() {
    let scheduler = Scheduler()
    let focus = DeferredPaneFocus(schedule: { scheduler.actions.append($0) })
    var focused: [String] = []
    focus.request(isCurrent: { true }) {
      focused.append("first")
      focus.request(isCurrent: { true }) {
        focused.append("second")
        return true
      }
      return true
    }
    scheduler.run()
    #expect(focused == ["first"])
    scheduler.run()
    #expect(focused == ["first", "second"])
  }

  @Test("Inside an immediate scope a ready pane takes focus at once and the queue confirms it")
  func immediateScopeFocusesReadyPane() {
    let scheduler = Scheduler()
    let focus = DeferredPaneFocus(schedule: { scheduler.actions.append($0) })
    var attempts = 0

    DeferredPaneFocus.attemptingNow {
      focus.request(isCurrent: { true }) {
        attempts += 1
        return true
      }
    }

    #expect(attempts == 1)
    scheduler.run()
    #expect(attempts == 2)
    focus.retry()
    #expect(scheduler.actions.isEmpty)
  }

  @Test("Inside an immediate scope a pane that is not ready yet still gets focus once it is")
  func immediateScopeFallsBackToTheQueue() {
    let scheduler = Scheduler()
    let focus = DeferredPaneFocus(schedule: { scheduler.actions.append($0) })
    var attached = false
    var attempts = 0

    DeferredPaneFocus.attemptingNow {
      focus.request(isCurrent: { true }) {
        attempts += 1
        return attached
      }
    }
    attached = true
    scheduler.run()

    #expect(attempts == 2)
    #expect(scheduler.actions.isEmpty)
  }

  @Test("Outside an immediate scope focus still waits for the queue")
  func focusWaitsOutsideTheScope() {
    let scheduler = Scheduler()
    let focus = DeferredPaneFocus(schedule: { scheduler.actions.append($0) })
    var focused = false

    DeferredPaneFocus.attemptingNow {}
    focus.request(isCurrent: { true }) {
      focused = true
      return true
    }

    #expect(!focused)
    scheduler.run()
    #expect(focused)
  }

  @Test("Inside an immediate scope a pane that cannot take focus yet is asked again from the queue")
  func immediateScopeWaitsForAPaneThatIsNotCurrentYet() {
    let scheduler = Scheduler()
    let focus = DeferredPaneFocus(schedule: { scheduler.actions.append($0) })
    var current = false
    var focused = false

    DeferredPaneFocus.attemptingNow {
      focus.request(isCurrent: { current }) {
        focused = true
        return true
      }
    }
    current = true
    scheduler.run()

    #expect(focused)
  }
}
