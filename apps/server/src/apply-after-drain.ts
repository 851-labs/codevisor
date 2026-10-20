import type { RestartCoordinator } from "./restart-drain.js"

export const applyAfterDrain = async (
  restart: RestartCoordinator,
  publish: () => void,
  apply: () => Promise<void>
): Promise<void> => {
  const drained = await restart.begin()
  if (drained.state !== "drained") return
  publish()
  try {
    await apply()
  } catch {
    await restart.cancel()
  }
}
