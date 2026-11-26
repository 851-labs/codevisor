import type { DesktopStatus } from "@codevisor/api"

import {
  APT_UPDATE_LOOP,
  fakeMachine,
  type FakeMachineOptions,
  UBUNTU
} from "../desktop/desktop-test-support.js"
import type { DesktopCliDeps } from "./desktop.js"
import { type FakeOptions, makeWorld } from "./support-test-support.js"

export const url = (path = "") => `http://127.0.0.1:49361/v1/desktop${path}`
export const apt = "env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600"
export const aptUpdate = `env DEBIAN_FRONTEND=noninteractive sh -c ${APT_UPDATE_LOOP}`
export const aptUpdateShown = `env DEBIAN_FRONTEND=noninteractive sh -c '${APT_UPDATE_LOOP}'`
export const aptInstall = `${apt} install -y -q --no-install-recommends tigervnc-standalone-server tigervnc-common xfce4 xfce4-terminal dbus-x11 xclip python3 fonts-dejavu-core adwaita-icon-theme`
export const missing = ["Xvnc", "startxfce4"]
export const busy = "Installing packages"
export const withAnOldRootDesktop: FakeMachineOptions = {
  files: {
    ...UBUNTU,
    "/etc/systemd/system/vncserver@.service": "[Unit]\nDescription=Codevisor desktop, TigerVNC\n"
  },
  folders: { "/etc/systemd/system/multi-user.target.wants": ["vncserver@1.service"] }
}
export const removeTheOldOne = [
  "systemctl disable --now vncserver@1.service",
  "rm -f /etc/systemd/system/vncserver@.service",
  "systemctl daemon-reload"
]

export const status = (changes: Partial<DesktopStatus> = {}): DesktopStatus => ({
  state: "none",
  account: "codevisor",
  system: "Ubuntu 24.04.5 LTS",
  missing: [],
  sudo: "passwordless",
  startsAtBoot: true,
  logHint: "journalctl --user -u codevisor-desktop",
  ...changes
})

export const answers = (...bodies: unknown[]) => bodies.map((body) => ({ status: 200, body }))
export const running = status({ state: "running", display: 1, managed: true, keepsRunning: true })

export interface Terminal {
  readonly interactive?: boolean
  readonly agrees?: boolean
  readonly isRoot?: boolean
  readonly sudoFails?: boolean
  readonly machine?: FakeMachineOptions
}

export const world = (http: FakeOptions["http"], terminal: Terminal = {}) => {
  const fake = makeWorld({
    http: http ?? {},
    isRoot: terminal.isRoot ?? false,
    ...(terminal.sudoFails === true ? { interactiveExit: 100 } : {})
  })
  const questions: string[] = []
  const deps: DesktopCliDeps = {
    ...fake.deps,
    isInteractive: terminal.interactive ?? true,
    confirm: async (question) => {
      questions.push(question)
      return terminal.agrees ?? true
    },
    system: fakeMachine({ files: UBUNTU, ...terminal.machine }).system
  }
  return { ...fake, deps, questions }
}
