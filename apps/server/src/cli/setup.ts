/// `codevisor setup` — interactive onboarding for a freshly installed machine:
/// pick how clients should reach this server (Tailscale recommended), issue a
/// connection token, and print the exact steps plus a codevisor:// deeplink.
/// Logic lives behind the same injectable seam as the other CLI commands; the
/// real prompt implementations are wired in cli.ts.
import {
  DEFAULT_PORT,
  resolvePort,
  startCommand,
  type CliDeps,
  type CommandOptions
} from "./support.js"

export interface SelectChoice<A> {
  readonly title: string
  readonly value: A
  readonly description?: string
}

export interface SetupPrompts {
  readonly select: <A>(message: string, choices: ReadonlyArray<SelectChoice<A>>) => Promise<A>
  readonly text: (message: string) => Promise<string>
}

export interface SetupDeps extends CliDeps {
  readonly hostname: string
  readonly isInteractive: boolean
  readonly prompts: SetupPrompts
}

export interface TailscaleInfo {
  readonly ip: string
  readonly dnsName?: string
}

/// Machine-side Tailscale probe: the CLI on PATH covers Linux and the
/// open-source macOS install; the app-bundle binary covers the GUI installs.
export const detectTailscale = async (deps: CliDeps): Promise<TailscaleInfo | undefined> => {
  for (const binary of ["tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]) {
    const result = await deps.exec(binary, ["status", "--json"])
    if (result.code !== 0) continue
    try {
      const status = JSON.parse(result.stdout) as {
        readonly Self?: { readonly TailscaleIPs?: unknown; readonly DNSName?: unknown }
      }
      const ips = status.Self?.TailscaleIPs
      const ip = Array.isArray(ips) ? ips.find((value) => typeof value === "string") : undefined
      if (typeof ip === "string" && ip.length > 0) {
        const dnsName =
          typeof status.Self?.DNSName === "string" && status.Self.DNSName.length > 0
            ? status.Self.DNSName.replace(/\.$/, "")
            : undefined
        return { ip, ...(dnsName === undefined ? {} : { dnsName }) }
      }
    } catch {
      // Unparseable status output; try the next binary.
    }
  }
  return undefined
}

export const detectPublicIp = async (deps: CliDeps): Promise<string | undefined> => {
  const response = await deps.fetchJson("https://api.ipify.org?format=json")
  const ip = (response?.body as { readonly ip?: string } | undefined)?.ip
  return typeof ip === "string" && ip.length > 0 ? ip : undefined
}

export interface DeeplinkParams {
  readonly host: string
  readonly port: number
  readonly token: string
  readonly name: string
}

export const addMachineDeeplink = (params: DeeplinkParams): string => {
  const query = new URLSearchParams({
    host: params.host,
    port: String(params.port),
    token: params.token,
    name: params.name
  })
  return `codevisor://add-machine?${query.toString()}`
}

type Connectivity = "tailscale" | "public" | "custom"

const chooseHost = async (
  deps: SetupDeps,
  port: number
): Promise<{ readonly host: string; readonly firewallNote: boolean } | undefined> => {
  const tailscale = await detectTailscale(deps)
  if (tailscale === undefined) {
    deps.log("Tip: Tailscale is the recommended way to reach this machine securely.")
    deps.log("     Install it on this machine and your Mac (https://tailscale.com/download),")
    deps.log("     then re-run: codevisor setup")
    deps.log("")
  }
  const choices: Array<SelectChoice<Connectivity>> = [
    ...(tailscale === undefined
      ? []
      : [
          {
            title: "Tailscale (recommended)",
            value: "tailscale" as const,
            description: `Private tailnet connection via ${tailscale.dnsName ?? tailscale.ip}`
          }
        ]),
    {
      title: "Public IP",
      value: "public",
      description: `Direct connection; you must allow TCP ${port} through this machine's firewall`
    },
    {
      title: "Other (VPN or custom address)",
      value: "custom",
      description: "Enter the address clients should use to reach this machine"
    }
  ]
  const choice = await deps.prompts.select<Connectivity>(
    "How should clients connect to this machine?",
    choices
  )
  if (choice === "tailscale" && tailscale !== undefined) {
    return { host: tailscale.dnsName ?? tailscale.ip, firewallNote: false }
  }
  if (choice === "public") {
    const detected = await detectPublicIp(deps)
    if (detected !== undefined) return { host: detected, firewallNote: true }
    deps.log("Could not detect this machine's public IP automatically.")
    const entered = await deps.prompts.text("Public IP or hostname for this machine")
    return entered.trim().length === 0 ? undefined : { host: entered.trim(), firewallNote: true }
  }
  const entered = await deps.prompts.text("Address clients should use (IP or hostname)")
  return entered.trim().length === 0 ? undefined : { host: entered.trim(), firewallNote: false }
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

  const connection = await chooseHost(deps, port)
  if (connection === undefined) {
    deps.error("No address entered; re-run codevisor setup to finish onboarding.")
    return 1
  }

  const response = await deps.fetchJson(`http://127.0.0.1:${port}/v1/auth/connection-token`)
  const token = (response?.body as { readonly token?: string } | undefined)?.token
  if (response === undefined || response.status !== 200 || token === undefined) {
    deps.error("Could not issue a connection token; is the server healthy? (codevisor status)")
    return 1
  }

  const name = deps.hostname
  const host = port === DEFAULT_PORT ? connection.host : `${connection.host}:${port}`
  deps.log("")
  deps.log("This machine is ready for Codevisor.")
  deps.log("")
  deps.log(`  Name               ${name}`)
  deps.log(`  Host               ${host}`)
  deps.log(`  Connection token   ${token}`)
  deps.log("")
  if (connection.firewallNote) {
    deps.log(`Firewall: allow inbound TCP ${port} on this machine`)
    deps.log(`  e.g. sudo ufw allow ${port}/tcp`)
    deps.log("")
  }
  deps.log("Connect from Codevisor on your Mac:")
  deps.log("  1. Open Settings → Machines → Add Remote Machine")
  deps.log("  2. Enter the Name, Host, and Connection token shown above")
  deps.log("")
  deps.log("Or open this link on your Mac to add the machine automatically:")
  deps.log(`  ${addMachineDeeplink({ host: connection.host, port, token, name })}`)
  deps.log("")
  deps.log("Keep the token private — anyone with it can run agents on this machine.")
  return 0
}
