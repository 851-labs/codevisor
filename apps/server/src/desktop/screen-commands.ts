export type ScreenKind = "x11" | "wlroots"

export interface ShownScreen {
  readonly kind: ScreenKind
  readonly shows: string
  readonly env: Readonly<Record<string, string>>
}

export interface Scraper {
  readonly program: string
  readonly hasControlSocket?: boolean
  readonly tooOld?: string
}

export interface HelperCommand {
  readonly program: string
  readonly args: ReadonlyArray<string>
}

export const X11_SCRAPERS = ["X0tigervnc", "x0vncserver"] as const
export const WLROOTS_SCRAPERS = ["wayvnc"] as const
export const WLROOTS_COMPOSITORS: ReadonlySet<string> = new Set([
  "sway",
  "Hyprland",
  "river",
  "labwc",
  "wayfire"
])

export const helperCommand = (
  scraper: Scraper,
  shown: ShownScreen,
  socket: string
): HelperCommand => {
  if (scraper.program === "wayvnc") return wayvnc(shown, socket, scraper.hasControlSocket === true)

  return x0vncserver(scraper.program, shown, socket)
}

export const helperName = (scraper: string): string =>
  scraper === "X0tigervnc" ? "x0vncserver" : scraper

export const controlSocketOf = (socket: string): string => `${socket}.ctl`

export const asAssignments = (env: Readonly<Record<string, string>>): ReadonlyArray<string> =>
  Object.entries(env).map(([name, value]) => `${name}=${value}`)

const x0vncserver = (scraper: string, shown: ShownScreen, socket: string): HelperCommand => ({
  program: "env",
  args: [
    ...asAssignments(shown.env),
    scraper,
    "-display",
    shown.shows,
    "-rfbunixpath",
    socket,
    "-rfbunixmode",
    "0600",
    "-rfbport",
    "-1",
    "-localhost",
    "-SecurityTypes",
    "None",
    "-AcceptSetDesktopSize=0"
  ]
})

const privateFilesThen = 'umask 077 && exec "$@"'

const wayvnc = (shown: ShownScreen, socket: string, hasControlSocket: boolean): HelperCommand => ({
  program: "sh",
  args: [
    "-c",
    privateFilesThen,
    "sh",
    "env",
    ...asAssignments(shown.env),
    "wayvnc",
    "--config=/dev/null",
    "--render-cursor",
    ...(hasControlSocket ? [`--socket=${controlSocketOf(socket)}`] : []),
    "--unix-socket",
    socket
  ]
})
