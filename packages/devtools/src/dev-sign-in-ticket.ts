import { mkdir, readFile, writeFile } from "node:fs/promises"
import { join } from "node:path"

export type SignInTicketApp = "macos" | "ios"

export async function offerDevelopmentSignIn(options: {
  readonly root: string
  readonly app: SignInTicketApp
  readonly device: string
}): Promise<string> {
  const ticket = join(options.root, `${options.app}.ticket`)
  const offered = join(options.root, `${options.app}.offered`)
  const lastDevice = await readFile(offered, "utf8").catch(() => undefined)
  if (lastDevice === options.device) return ticket

  await mkdir(options.root, { recursive: true })
  await writeFile(ticket, "")
  await writeFile(offered, options.device)
  return ticket
}
