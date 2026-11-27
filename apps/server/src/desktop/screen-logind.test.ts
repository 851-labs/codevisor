import { describe, expect, it } from "vitest"

import { accountsAtTheScreen } from "./screen-logind.js"
import { machine, type Process } from "./screen-session-test-support.js"

const shown = (session: string) =>
  `loginctl show-session ${session} -p Id -p Name -p Seat -p Class -p Remote -p State -p Type -p Display`

const session = (fields: Record<string, string>) => ({
  output: Object.entries(fields)
    .map(([name, value]) => `${name}=${value}\n`)
    .join("")
})

const local = { Seat: "seat0", Class: "user", Remote: "no", State: "active" }

const listing = (lines: string) => ({ "loginctl list-sessions --no-legend": { output: lines } })

const asking = (
  answers: Record<string, { code?: number; output: string }>,
  processes: Record<number, Process> = {}
) => machine({ processes, answers })

describe("who is logged in at the machine's screen", () => {
  it("is everyone logind has seated graphically, with the session and its display", async () => {
    const system = asking({
      ...listing(
        " 2 1000 alice seat0 tty2\n c1 120 gdm seat0 tty1\n 5 1001 bob - pts/0\n 7 1002 carol seat0 tty3\n"
      ),
      [shown("2")]: session({ Id: "2", Name: "alice", ...local, Type: "x11", Display: ":0" }),
      [shown("c1")]: session({ Id: "c1", Name: "gdm", ...local, Class: "greeter", Type: "x11" }),
      [shown("5")]: session({
        Id: "5",
        Name: "bob",
        ...local,
        Seat: "",
        Remote: "yes",
        Type: "x11"
      }),
      [shown("7")]: session({ Id: "7", Name: "carol", ...local, State: "closing", Type: "x11" })
    })

    expect(await accountsAtTheScreen(system)).toEqual([
      { account: "alice", type: "x11", session: "2", display: ":0" }
    ])
  })

  it("leaves out a session switched to the background, and takes the account's active one", async () => {
    const system = asking({
      ...listing(" 2 1000 alice seat0 tty2\n 3 1001 bob seat0 tty3\n 4 1000 alice seat0 tty4\n"),
      [shown("2")]: session({ Id: "2", Name: "alice", ...local, State: "online", Type: "wayland" }),
      [shown("3")]: session({ Id: "3", Name: "bob", ...local, State: "online", Type: "x11" }),
      [shown("4")]: session({ Id: "4", Name: "alice", ...local, Type: "x11", Display: ":1" })
    })

    expect(await accountsAtTheScreen(system)).toEqual([
      { account: "alice", type: "x11", session: "4", display: ":1" }
    ])
  })

  it("leaves out a text-console login, which isn't at the graphical screen", async () => {
    const system = asking({
      ...listing(" 3 1002 dave seat0 tty1\n"),
      [shown("3")]: session({ Id: "3", Name: "dave", ...local, Type: "tty" })
    })

    expect(await accountsAtTheScreen(system)).toEqual([])
  })

  it("counts a text-console login that started X with startx, on the X server's display", async () => {
    const system = asking(
      {
        ...listing(" 3 1000 alice seat0 tty1\n"),
        [shown("3")]: session({ Id: "3", Name: "alice", ...local, Type: "tty" })
      },
      {
        600: {
          comm: "Xorg",
          session: "3",
          cmdline: ["/usr/lib/xorg/Xorg", ":0", "vt1", "-keeptty"]
        }
      }
    )

    expect(await accountsAtTheScreen(system)).toEqual([
      { account: "alice", type: "x11", session: "3", display: ":0" }
    ])
  })

  it("trusts logind when it lists nobody at a seat, whatever who says about remote displays", async () => {
    const system = asking({
      ...listing(""),
      who: { output: "carol    :10          2026-11-26 17:18 (:10)\n" }
    })

    expect(await accountsAtTheScreen(system)).toEqual([])
  })

  it("asks who, for those recorded on a display, only where loginctl can't be asked", async () => {
    const system = asking({
      who: {
        output:
          "alice    tty7         2026-11-26 17:18 (:0)\nlightdm  :1           2026-11-26 17:10\nbob      pts/0        2026-11-26 17:19 (10.0.0.4)\n"
      }
    })

    expect(await accountsAtTheScreen(system)).toEqual([{ account: "alice", display: ":0" }])
  })

  it("is unknown when neither can be asked", async () => {
    expect(await accountsAtTheScreen(asking({}))).toBeUndefined()
  })
})
