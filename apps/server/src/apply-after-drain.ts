import type { RestartCoordinator, RestartDrainOptions } from "./restart-drain.js"

// The HTTP acknowledgement is sent before this task can restart the process.
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
