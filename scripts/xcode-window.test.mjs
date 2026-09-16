import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import test from "node:test"
import vm from "node:vm"

const context = vm.createContext({})
vm.runInContext(readFileSync(new URL("./xcode-window-owner.jxa", import.meta.url), "utf8"), context)
const { ownXcodeWindow, taskStopConfirmation, readXcodeAttribute } = context

function fixture() {
  const app = { pid: 42, launch: "original" }
  const other = { title: "Codevisor", path: "/other/Codevisor.xcodeproj" }
  const opened = { title: "Codevisor", path: "/owned/Codevisor.xcodeproj" }
  const state = { app, windows: [other] }
  const closed = []
  const ready = []
  const system = {
    snapshot: () => ({ app: state.app, windows: [...state.windows] }),
    sameApp: (left, right) => left === right,
    sameWindow: (left, right) => left === right,
    matchesProject: (window) => window.path === opened.path,
    open: () => state.windows.push(opened),
    ready: (owned) => ready.push(owned),
    waitForShutdown: () => {},
    close: (window) => closed.push(window),
    now: () => 0,
    pause: () => {
      throw new Error("Unexpected wait")
    }
  }
  return { app, other, opened, state, closed, ready, system }
}

test("EOF closes only the newly opened project window even when other titles match", () => {
  const f = fixture()
  f.system.waitForShutdown = () => {
    // Focus/order changes and a second window for the same project cannot retarget cleanup.
    f.state.windows = [{ ...f.opened }, f.other, f.opened]
  }
  ownXcodeWindow(f.system)
  assert.deepEqual(f.ready, [true])
  assert.deepEqual(f.closed, [f.opened])
})

test("an already open project is borrowed and never closed", () => {
  const f = fixture()
  f.state.windows.push(f.opened)
  f.system.open = () => {}
  ownXcodeWindow(f.system)
  assert.deepEqual(f.ready, [false])
  assert.deepEqual(f.closed, [])
})

test("closing and reopening the project does not transfer window ownership", () => {
  const f = fixture()
  f.system.waitForShutdown = () => {
    f.state.windows = [f.other, { ...f.opened }]
  }
  ownXcodeWindow(f.system)
  assert.deepEqual(f.closed, [])
})

test("Xcode exit or restart, including PID reuse, never closes a new window", () => {
  for (const replacement of [null, { pid: 42, launch: "replacement" }]) {
    const f = fixture()
    f.system.waitForShutdown = () => {
      f.state.app = replacement
    }
    ownXcodeWindow(f.system)
    assert.deepEqual(f.closed, [])
  }
})

test("a window that switches projects is left alone", () => {
  const f = fixture()
  const path = f.opened.path
  f.system.matchesProject = (window) => window.path === path
  f.system.waitForShutdown = () => {
    f.opened.path = f.other.path
  }
  ownXcodeWindow(f.system)
  assert.deepEqual(f.closed, [])
})

test("failure after acquisition still releases the owned window", () => {
  const f = fixture()
  f.system.ready = () => {
    throw new Error("Launcher disconnected")
  }
  assert.throws(() => ownXcodeWindow(f.system), /Launcher disconnected/)
  assert.deepEqual(f.closed, [f.opened])
})

test("ambiguous windows and an Xcode restart during opening fail without closing anything", () => {
  for (const mutate of [
    (f) => f.state.windows.push({ ...f.opened }),
    (f) => {
      f.state.app = { ...f.app }
    }
  ]) {
    const f = fixture()
    f.system.open = () => {
      f.state.windows.push(f.opened)
      mutate(f)
    }
    assert.throws(() => ownXcodeWindow(f.system), /ambiguous|restarted/)
    assert.deepEqual(f.ready, [])
    assert.deepEqual(f.closed, [])
  }
})

test("delayed project readiness and its deadline use the injected clock", () => {
  const f = fixture()
  f.system.open = () => {}
  f.system.pause = () => {
    f.state.windows.push(f.opened)
  }
  ownXcodeWindow(f.system)
  assert.deepEqual(f.closed, [f.opened])

  const missing = fixture()
  let time = 0
  missing.system.open = () => {}
  missing.system.now = () => time
  missing.system.pause = () => {
    time = 30000
  }
  assert.throws(() => ownXcodeWindow(missing.system), /Timed out/)
  assert.deepEqual(missing.closed, [])
})

test("only a new task-stop dialog for the still-owned main window may be confirmed", () => {
  const f = fixture()
  const button = {}
  const dialog = { modal: true, taskStopButton: button }
  const before = { app: f.app, windows: [f.other, f.opened] }
  const current = { ...before, windows: [...before.windows, dialog] }
  const system = {
    ...f.system,
    mainWindow: () => f.opened,
    isModal: (window) => window.modal === true,
    taskStopButton: (window) => window.taskStopButton ?? null
  }
  assert.equal(taskStopConfirmation(system, before, current, f.opened), button)
  for (const [sys, initial, live] of [
    [{ ...system, mainWindow: () => f.other }, before, current],
    [{ ...system, mainWindow: () => null }, before, current],
    [{ ...system, matchesProject: () => false }, before, current],
    [system, current, current], // Existing dialog, including one with the same text.
    [system, before, { ...current, app: { ...f.app } }],
    [system, before, { ...current, windows: [...current.windows, { ...dialog }] }],
    [system, before, { ...current, windows: [...before.windows, { modal: true }] }]
  ])
    assert.equal(taskStopConfirmation(sys, initial, live, f.opened), null)
})

test("transient AX read failures wait for a real snapshot without extending the deadline", () => {
  let time = 0
  const windows = [{}]
  const timeouts = []
  const system = {
    now: () => time,
    pause: () => {
      time = 4999
    },
    read: (timeout) => {
      timeouts.push(timeout)
      return time === 0 ? { status: -25204 } : { status: 0, value: windows }
    }
  }
  assert.equal(readXcodeAttribute(system, "AXWindows"), windows)
  assert.deepEqual(timeouts, [1000, 1])

  time = 0
  timeouts.length = 0
  system.read = (timeout) => {
    timeouts.push(timeout)
    if (time === 4999) time = 5000
    return { status: -25204 }
  }
  assert.throws(() => readXcodeAttribute(system, "AXWindows"), /AX error -25204/)
  assert.deepEqual(timeouts, [1000, 1])
})

test("AX read errors never masquerade as a missing window", () => {
  for (const status of [-25201, -25205, -25211]) {
    const system = {
      now: () => 0,
      read: () => ({ status }),
      pause: () => assert.fail("Non-transient errors must not retry")
    }
    assert.throws(() => readXcodeAttribute(system, "AXWindows"), /Cannot read AXWindows/)
  }
  for (const [status, name] of [
    [-25202, "AXWindows"],
    [-25212, "AXWindows"],
    [-25205, "AXDocument"]
  ]) {
    assert.equal(readXcodeAttribute({ now: () => 0, read: () => ({ status }) }, name), null)
  }
})
