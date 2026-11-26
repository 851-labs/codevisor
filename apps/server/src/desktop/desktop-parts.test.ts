import { mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, it, onTestFinished } from "vitest"

import { unitText } from "./desktop-service.js"
import { listeningPorts, somethingListensOn } from "./listening-ports.js"
import { xauthorityEntry } from "./xauthority.js"

const header =
  "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode"

describe("the TCP ports something on the machine listens on", () => {
  it("reads listening IPv4 sockets and leaves connected ones out", () => {
    const table = [
      header,
      "   0: 0100007F:170D 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1 1 0 100 0 0 10 0",
      "   1: 00000000:C0E1 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1001        0 2 1 0 100 0 0 10 0",
      "   2: 0100007F:170E 0100007F:D431 01 00000000:00000000 00:00000000 00000000  1001        0 3 1 0 20 4 30 10 -1",
      ""
    ].join("\n")
    expect([...listeningPorts(table)]).toEqual([5901, 49_377])
  })

  it("reads listening IPv6 sockets", () => {
    const table = [
      header,
      "   0: 00000000000000000000000001000000:170D 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 4 1 0 100 0 0 10 0",
      ""
    ].join("\n")
    expect(listeningPorts(table).has(5901)).toBe(true)
  })

  it("finds nothing in an empty table", () => {
    expect(listeningPorts(`${header}\n`).size).toBe(0)
  })

  it("takes the IPv6 table as empty when it is missing, as it is with IPv6 turned off", () => {
    const folder = mkdtempSync(join(tmpdir(), "cv-tcp-"))
    onTestFinished(() => rmSync(folder, { recursive: true, force: true }))
    const tcp = join(folder, "tcp")
    writeFileSync(
      tcp,
      `${header}\n   0: 0100007F:170D 00000000:0000 0A 00000000:00000000 00:00000000 00000000 0 0 1 1 0 100 0 0 10 0\n`
    )
    const ipv4 = { path: tcp }
    const ipv6TurnedOff = { path: join(folder, "tcp6"), absentWithoutIPv6: true }
    expect(somethingListensOn(5901, [ipv6TurnedOff, ipv4])).toBe(true)
    expect(somethingListensOn(5902, [ipv4, ipv6TurnedOff])).toBe(false)
    expect(somethingListensOn(5901, [ipv6TurnedOff])).toBe(false)
  })

  it("refuses to answer when the table it needs can't be read, instead of calling the port closed", () => {
    const unreadable = { path: join(tmpdir(), "cv-no-such-folder", "tcp") }
    expect(() => somethingListensOn(5901, [unreadable])).toThrow(
      `Can't read ${unreadable.path}, so the desktop's TCP port can't be checked`
    )
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
