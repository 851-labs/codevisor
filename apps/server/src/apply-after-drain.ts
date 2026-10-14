import type { RestartCoordinator, RestartDrainOptions } from "./restart-drain.js"

export const applyAfterDrain = async (
  restart: RestartCoordinator,
  options: RestartDrainOptions,
  publish: () => void,
  apply: () => Promise<void>
): Promise<void> => {
  const drained = await restart.begin(options)
  if (drained.state !== "drained") return
  publish()
  try {
    await apply()
  } catch {
    await restart.cancel()
  }
}
