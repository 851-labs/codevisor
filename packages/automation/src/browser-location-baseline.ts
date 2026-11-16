import type { CdpConnection } from "./browser-cdp.js"

interface LocationRuntime {
  readonly connection: CdpConnection
  readonly owned: boolean
}

export const withholdTabLocation = async (
  runtime: LocationRuntime,
  sessionId: string
): Promise<void> => {
  if (!runtime.owned) return

  await runtime.connection
    .send("Emulation.setGeolocationOverride", {}, sessionId)
    .catch(() => undefined)
}
