/// `codevisor setup` — onboarding for a freshly installed machine: start the
/// server, then sign it into Codevisor Cloud (the `codevisor auth login`
/// device flow) so it appears in every Codevisor app on the account. Logic
/// lives behind the same injectable seam as the other CLI commands; the
/// real login is wired in cli.ts.
import { readCloudRegistration } from "./cloud-control.js"
import { resolvePort, startCommand, type CliDeps, type CommandOptions } from "./support.js"

export interface SetupDeps extends CliDeps {
  readonly isInteractive: boolean
  /// Runs the cloud device-code login against the server on `port` and
  /// verifies its relay connection; resolves to an exit code.
  readonly cloudLogin: (port: number) => Promise<number>
}

export const setupCommand = async (
  deps: SetupDeps,
  options: CommandOptions = {}
): Promise<number> => {
  if (deps.env["CODEVISOR_NO_SETUP"] === "1") {
    deps.log("Skipping setup (CODEVISOR_NO_SETUP=1). Run later with: codevisor setup")
    return 0
  }
  if (!deps.isInteractive) {
    deps.error("codevisor setup needs an interactive terminal.")
    deps.error("Run it from a shell on this machine: codevisor setup")
    return 1
  }

  const started = await startCommand(deps, options)
  if (started !== 0) return started
  const port = await resolvePort(deps, options.port)

  const registration = await readCloudRegistration(deps, port)
  if (registration?.deviceId !== undefined) {
    deps.log(
      `✓ This machine is already connected to your ${registration.serverUrl ?? "Codevisor Cloud"} account.`
    )
    deps.log("Check its connection any time with: codevisor auth status")
    return 0
  }

  if ((await deps.cloudLogin(port)) !== 0) {
    deps.error("Setup didn't finish: this machine is not connected to your account yet.")
    deps.error("Retry with: codevisor auth login")
    return 1
  }
  deps.log("")
  deps.log("✓ Setup complete. This machine appears in every Codevisor app signed in to")
  deps.log("  your account.")
  return 0
}
