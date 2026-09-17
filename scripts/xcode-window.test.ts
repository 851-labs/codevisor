import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import test from "node:test"
import vm from "node:vm"

/// The running Xcode and its windows are opaque accessibility references at
/// runtime; the fixtures below stand in for them with the identity the script
/// compares and the project path it matches on.
interface XcodeApp {
  pid: number
  launch: string
}

interface XcodeWindow {
  title?: string
  path?: string
  modal?: boolean
  taskStopButton?: object
}

interface XcodeSnapshot {
  app: XcodeApp | null
  windows: XcodeWindow[]
}

/// Every collaborator `ownXcodeWindow` reaches for.
interface XcodeSystem {
  snapshot: () => XcodeSnapshot
  sameApp: (left: XcodeApp | null, right: XcodeApp | null) => boolean
  sameWindow: (left: XcodeWindow | null, right: XcodeWindow | null) => boolean
  matchesProject: (window: XcodeWindow) => boolean
  open: () => void
  ready: (owned: boolean) => void
  waitForShutdown: () => void
  close: (window: XcodeWindow) => void
  now: () => number
  pause: () => void
}

/// The extra lookups `taskStopConfirmation` performs on a live snapshot.
interface XcodeDialogSystem extends XcodeSystem {
  mainWindow: (app: XcodeApp | null) => XcodeWindow | null
  isModal: (window: XcodeWindow) => boolean
  taskStopButton: (window: XcodeWindow) => object | null
}

/// One accessibility read, retried by `readXcodeAttribute` within its budget.
interface XcodeAttributeSystem {
  now: () => number
  pause?: () => void
  read: (timeout: number) => { status: number; value?: unknown }
}

/// The three functions the JXA source defines in the evaluation context.
interface XcodeWindowOwner {
  ownXcodeWindow: (system: XcodeSystem) => void
  taskStopConfirmation: (
    system: XcodeDialogSystem,
    before: XcodeSnapshot,
    current: XcodeSnapshot,
    window: XcodeWindow
  ) => object | null
  readXcodeAttribute: (system: XcodeAttributeSystem, name: string) => unknown
}

const context = vm.createContext({})
vm.runInContext(readFileSync(new URL("./xcode-window-owner.jxa", import.meta.url), "utf8"), context)
const { ownXcodeWindow, taskStopConfirmation, readXcodeAttribute } = context as XcodeWindowOwner

function fixture() {
  const app: XcodeApp = { pid: 42, launch: "original" }
  const other: XcodeWindow = { title: "Codevisor", path: "/other/Codevisor.xcodeproj" }
  const opened: XcodeWindow = { title: "Codevisor", path: "/owned/Codevisor.xcodeproj" }
  const state: XcodeSnapshot = { app, windows: [other] }
  const closed: XcodeWindow[] = []
  const ready: boolean[] = []
  const system: XcodeSystem = {
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

type XcodeFixture = ReturnType<typeof fixture>

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
  const mutations: ((f: XcodeFixture) => void)[] = [
    (f) => f.state.windows.push({ ...f.opened }),
    (f) => {
      f.state.app = { ...f.app }
    }
  ]
  for (const mutate of mutations) {
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
  const dialog: XcodeWindow = { modal: true, taskStopButton: button }
  const before: XcodeSnapshot = { app: f.app, windows: [f.other, f.opened] }
  const current: XcodeSnapshot = { ...before, windows: [...before.windows, dialog] }
  const system: XcodeDialogSystem = {
    ...f.system,
    mainWindow: () => f.opened,
    isModal: (window) => window.modal === true,
    taskStopButton: (window) => window.taskStopButton ?? null
  }
  assert.equal(taskStopConfirmation(system, before, current, f.opened), button)
  const rejected: [XcodeDialogSystem, XcodeSnapshot, XcodeSnapshot][] = [
    [{ ...system, mainWindow: () => f.other }, before, current],
    [{ ...system, mainWindow: () => null }, before, current],
    [{ ...system, matchesProject: () => false }, before, current],
    [system, current, current], // Existing dialog, including one with the same text.
    [system, before, { ...current, app: { ...f.app } }],
    [system, before, { ...current, windows: [...current.windows, { ...dialog }] }],
    [system, before, { ...current, windows: [...before.windows, { modal: true }] }]
  ]
  for (const [sys, initial, live] of rejected)
    assert.equal(taskStopConfirmation(sys, initial, live, f.opened), null)
})

test("transient AX read failures wait for a real snapshot without extending the deadline", () => {
  let time = 0
  const windows = [{}]
  const timeouts: number[] = []
  const system: XcodeAttributeSystem = {
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
    const system: XcodeAttributeSystem = {
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
  ] as const) {
    assert.equal(readXcodeAttribute({ now: () => 0, read: () => ({ status }) }, name), null)
  }
})
