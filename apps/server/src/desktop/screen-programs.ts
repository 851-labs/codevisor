import {
  knowsAbout,
  missingFor,
  type ScreenProgram,
  type ScreenPrograms,
  screenKindsOfTheMachine,
  screenPrograms
} from "./desktop-packages.js"
import type { DesktopSystem } from "./desktop-system.js"
import type { Scraper, ScreenKind } from "./screen-commands.js"

export interface KnownScreenPrograms {
  readonly programs: (kinds: ReadonlyArray<ScreenKind>) => Promise<ScreenPrograms>
  readonly kindsOfTheMachine: () => Promise<ReadonlyArray<ScreenKind>>
  readonly missing: (kinds: ReadonlyArray<ScreenKind>) => Promise<ReadonlyArray<ScreenProgram>>
  readonly tooOld: (kinds: ReadonlyArray<ScreenKind>) => Promise<string | undefined>
  readonly checkAgain: () => void
}

interface Known<Value> {
  readonly value: Value
  readonly at: number
}

const stayKnownMs = 30_000

export const knownScreenPrograms = (
  system: DesktopSystem,
  now: () => number
): KnownScreenPrograms => {
  let installed: Known<ScreenPrograms> | undefined
  let machineKinds: Known<ReadonlyArray<ScreenKind>> | undefined

  const fresh = <Value>(known: Known<Value> | undefined): Value | undefined =>
    known !== undefined && now() - known.at < stayKnownMs ? known.value : undefined

  const programs = async (kinds: ReadonlyArray<ScreenKind>): Promise<ScreenPrograms> => {
    const known = fresh(installed)
    if (known !== undefined && knowsAbout(known, kinds) && missingFor(known, kinds).length === 0)
      return known

    const found = await screenPrograms(system, kinds)
    installed = { value: found, at: now() }
    return found
  }

  const kindsOfTheMachine = async (): Promise<ReadonlyArray<ScreenKind>> => {
    const known = fresh(machineKinds)
    if (known !== undefined) return known

    const found = await screenKindsOfTheMachine(system)
    machineKinds = { value: found, at: now() }
    return found
  }

  return {
    programs,
    kindsOfTheMachine,
    missing: async (kinds) => missingFor(await programs(kinds), kinds),
    tooOld: async (kinds) => {
      const scrapers = (await programs(kinds)).scrapers
      const texts = kinds.map((kind) => tooOldText(scrapers.get(kind)))
      return texts.every((text) => text !== undefined) ? texts[0] : undefined
    },
    checkAgain: () => {
      installed = undefined
      machineKinds = undefined
    }
  }
}

export const tooOldText = (scraper: Scraper | undefined): string | undefined =>
  scraper?.tooOld === undefined
    ? undefined
    : `${scraper.program} ${scraper.tooOld} is too old; 0.5 or newer is needed`

export const noScraperFor = (kind: ScreenKind): string =>
  kind === "x11"
    ? "x0vncserver (TigerVNC's server for an existing screen) isn't installed"
    : "wayvnc (the VNC server for wlroots sessions) isn't installed"
