import { readFile, readdir, rm, writeFile } from "node:fs/promises"
import { join } from "node:path"
import process from "node:process"
import { fileURLToPath } from "node:url"

const here = fileURLToPath(new URL(".", import.meta.url))

const formatted = (toml) =>
  toml
    .split("\n")
    .map((line) => line.trimStart())
    .join("\n")

export const flyToml = (relay) => formatted(relayToml(relay))

const relayToml = (relay) => `app = "codevisor-${relay.id}"
primary_region = "${relay.region}"
kill_signal = "SIGTERM"
kill_timeout = 10

[build]
  image = "registry.fly.io/codevisor-relay:latest"

[env]
  RELAY_HOSTNAME = "${relay.hostname}"
  RELAY_AUTHORIZE_URL = "https://cloud.codevisor.dev/api/relay/authorize"
  RUST_LOG = "info"

[deploy]
  strategy = "rolling"

[mounts]
  source = "relay_data"
  destination = "/data"

[[services]]
  protocol = "udp"
  internal_port = 7842
  auto_stop_machines = "off"
  min_machines_running = 1

  [[services.ports]]
    port = 7842

[[services]]
  protocol = "tcp"
  internal_port = 443
  auto_stop_machines = "off"
  min_machines_running = 1

  [[services.ports]]
    port = 443
    handlers = []

  [services.concurrency]
    type = "connections"
    soft_limit = 8000
    hard_limit = 10000

  [[services.tcp_checks]]
    interval = "15s"
    timeout = "2s"
    grace_period = "60s"

  [[services.http_checks]]
    interval = "15s"
    timeout = "2s"
    grace_period = "120s"
    method = "get"
    path = "/healthz"
    protocol = "https"
    tls_skip_verify = true

[[services]]
  protocol = "tcp"
  internal_port = 80
  auto_stop_machines = "off"
  min_machines_running = 1

  [[services.ports]]
    port = 80
    handlers = []

[metrics]
  port = 9090
  path = "/metrics"

[[vm]]
  size = "shared-cpu-1x"
  memory = "1gb"
`

export async function readRelays() {
  return JSON.parse(await readFile(join(here, "relays.json"), "utf8"))
}

async function main(check) {
  const { relays } = await readRelays()
  const flyDir = join(here, "fly")
  const expected = new Map(relays.map((relay) => [`${relay.id}.toml`, flyToml(relay)]))
  const drift = []
  for (const [name, content] of expected) {
    const current = await readFile(join(flyDir, name), "utf8").catch(() => undefined)
    if (current === content) continue
    if (check) drift.push(`${name} is out of date`)
    else await writeFile(join(flyDir, name), content)
  }
  for (const name of await readdir(flyDir)) {
    if (expected.has(name)) continue
    if (check) drift.push(`${name} has no relays.json entry`)
    else await rm(join(flyDir, name))
  }
  if (drift.length > 0) {
    console.error(`apps/relay/fly drifted from relays.json (run node apps/relay/gen-fly.mjs):`)
    for (const line of drift) console.error(`  ${line}`)
    process.exitCode = 1
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  await main(process.argv.includes("--check"))
}
