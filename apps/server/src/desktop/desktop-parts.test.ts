import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, it, onTestFinished } from "vitest"

import { unitText } from "./desktop-service.js"
import { tcpPortsListenedOnBy } from "./listening-ports.js"
import { xauthorityEntry } from "./xauthority.js"

const header =
  "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode"

const line = (local: string, state: string, inode: number): string =>
  `   0: ${local} 00000000:0000 ${state} 00000000:00000000 00:00000000 00000000  1001        0 ${inode} 1 0000000000000000 100 0 0 10 0`

const fakeProc = (tables: Record<string, string>, sockets: Record<number, number[]>): string => {
  const proc = mkdtempSync(join(tmpdir(), "cv-proc-"))
  onTestFinished(() => rmSync(proc, { recursive: true, force: true }))
  mkdirSync(join(proc, "net"))
  for (const [name, text] of Object.entries(tables)) writeFileSync(join(proc, "net", name), text)
  for (const [pid, inodes] of Object.entries(sockets)) {
    mkdirSync(join(proc, pid, "fd"), { recursive: true })
    symlinkSync("/dev/null", join(proc, pid, "fd", "0"))
    inodes.forEach((inode, fd) =>
      symlinkSync(`socket:[${inode}]`, join(proc, pid, "fd", String(fd + 3)))
    )
  }
  return proc
}

describe("the TCP ports the desktop's own X server listens on", () => {
  const ipv4 = [header, line("0100007F:170D", "0A", 111), line("00000000:C0E1", "0A", 222)]
  const ipv6 = [header, line("00000000000000000000000001000000:170E", "0A", 333)]

  it("are the listening sockets that belong to that process, on IPv4 and IPv6", () => {
    const proc = fakeProc({ tcp: ipv4.join("\n"), tcp6: ipv6.join("\n") }, { 500: [111, 333, 999] })
    expect(tcpPortsListenedOnBy(500, proc)).toEqual([5901, 5902])
  })

  it("leave out another program's listener on the very port a desktop would use, and connected sockets", () => {
    const connected = line("0100007F:170D", "01", 444)
    const proc = fakeProc({ tcp: [...ipv4, connected].join("\n"), tcp6: header }, { 500: [444] })
    expect(tcpPortsListenedOnBy(500, proc)).toEqual([])
  })

  it("take the IPv6 table as empty when it is missing, as it is with IPv6 turned off", () => {
    const proc = fakeProc({ tcp: ipv4.join("\n") }, { 500: [222] })
    expect(tcpPortsListenedOnBy(500, proc)).toEqual([49_377])
  })

  it("can't be told when the kernel's table or the process's sockets can't be read, and that is an error", () => {
    const noTable = fakeProc({}, { 500: [111] })
    expect(() => tcpPortsListenedOnBy(500, noTable)).toThrow(
      `Can't read ${join(noTable, "net", "tcp")}, so the desktop's TCP ports can't be checked`
    )
    const noProcess = fakeProc({ tcp: ipv4.join("\n") }, {})
    expect(() => tcpPortsListenedOnBy(500, noProcess)).toThrow("can't be checked")
  })
})

describe("the X11 cookie file", () => {
  it("holds one entry that any client on the display can present: no host, no display number, a 16-byte cookie", () => {
    const cookie = Buffer.from("00112233445566778899aabbccddeeff", "hex")
    const name = Buffer.from("MIT-MAGIC-COOKIE-1", "latin1")
    expect(xauthorityEntry(cookie)).toEqual(
      Buffer.concat([
        Buffer.from([0xff, 0xff, 0, 0, 0, 0, 0, name.length]),
        name,
        Buffer.from([0, 16]),
        cookie
      ])
    )
  })

  it("gets a different cookie each time", () => {
    expect(xauthorityEntry().equals(xauthorityEntry())).toBe(false)
  })
})

describe("the desktop's boot service", () => {
  it("quotes its command so a folder with a space, a quote or a percent sign survives systemd", () => {
    const unit = unitText({
      program: "/opt/code visor/bin/node",
      args: ['/opt/a"b/cli.js', "desktop", "run", "--data-dir", "/data/100%/$team"]
    })
    expect(unit).toContain(
      'ExecStart="/opt/code visor/bin/node" "/opt/a\\"b/cli.js" "desktop" "run" "--data-dir" "/data/100%%/$$team"'
    )
    expect(unit).toContain("Restart=on-failure")
  })
})
