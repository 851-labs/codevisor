// Idempotent provisioning for one relay (deploy-relays.yml runs it before
// every deploy): the Fly app, dedicated IPv4 + IPv6, the relay_data volume,
// the staged RELAY_AUTHORIZE_TOKEN secret, and grey-cloud A/AAAA records in
// Cloudflare. Creates what's missing; never deletes anything.
//
// Env: FLY_API_TOKEN, CLOUDFLARE_API_TOKEN (the same token deploy-cloud.yml
//      uses; needs Zone:DNS:Edit + Zone:Zone:Read on codevisor.dev),
//      RELAY_AUTHORIZE_TOKEN, and optionally CLOUDFLARE_ZONE_ID (otherwise
//      the zone is looked up by name).
// Usage: node infra/relays/provision.mjs <relay-id>
import { execFile } from "node:child_process"
import process from "node:process"
import { promisify } from "node:util"

import { readRelays } from "./gen-fly.mjs"

const exec = promisify(execFile)
const fly = async (...args) => (await exec("flyctl", args, { maxBuffer: 16 << 20 })).stdout
const flyJson = async (...args) => JSON.parse((await fly(...args, "--json")) || "null")

const required = (name) => {
  const value = process.env[name]
  if (!value) throw new Error(`${name} is required`)
  return value
}

async function ensureApp(app, org) {
  const apps = (await flyJson("apps", "list")) ?? []
  if (apps.some((entry) => entry.Name === app || entry.name === app)) return
  console.log(`creating Fly app ${app}`)
  await fly("apps", "create", app, "--org", org)
}

async function ensureIps(app) {
  const ips = (await flyJson("ips", "list", "-a", app)) ?? []
  const has = (type) => ips.some((ip) => (ip.Type ?? ip.type) === type)
  if (!has("v4")) await fly("ips", "allocate-v4", "-a", app, "--yes")
  if (!has("v6")) await fly("ips", "allocate-v6", "-a", app)
  const refreshed = (await flyJson("ips", "list", "-a", app)) ?? []
  const address = (type) => refreshed.find((ip) => (ip.Type ?? ip.type) === type)?.Address
  return { v4: address("v4"), v6: address("v6") }
}

async function ensureVolume(app, region) {
  const volumes = (await flyJson("volumes", "list", "-a", app)) ?? []
  if (volumes.some((volume) => (volume.Name ?? volume.name) === "relay_data")) return
  console.log(`creating relay_data volume for ${app} in ${region}`)
  await fly(
    "volumes",
    "create",
    "relay_data",
    "-a",
    app,
    "--region",
    region,
    "--size",
    "1",
    "--yes"
  )
}

const cloudflareHeaders = () => ({
  authorization: `Bearer ${required("CLOUDFLARE_API_TOKEN")}`,
  "content-type": "application/json"
})

/// The zone that holds `hostname` (its last two labels, e.g. codevisor.dev).
async function zoneId(hostname) {
  if (process.env.CLOUDFLARE_ZONE_ID) return process.env.CLOUDFLARE_ZONE_ID
  const name = hostname.split(".").slice(-2).join(".")
  const url = `https://api.cloudflare.com/client/v4/zones?name=${name}`
  const listed = await (await fetch(url, { headers: cloudflareHeaders() })).json()
  const zone = listed.result?.[0]?.id
  if (!listed.success || zone === undefined) {
    throw new Error(
      `Cloudflare zone ${name} not found (the token needs Zone:Zone:Read): ` +
        JSON.stringify(listed.errors ?? [])
    )
  }
  return zone
}

async function ensureDns(hostname, type, content) {
  const zone = await zoneId(hostname)
  const headers = cloudflareHeaders()
  const base = `https://api.cloudflare.com/client/v4/zones/${zone}/dns_records`
  const listed = await (await fetch(`${base}?type=${type}&name=${hostname}`, { headers })).json()
  const existing = listed.result?.[0]
  // DNS-only: Cloudflare's proxy would break the relay's own TLS and UDP.
  const body = JSON.stringify({ type, name: hostname, content, proxied: false, ttl: 300 })
  if (existing?.content === content && existing.proxied === false) return
  const response = await fetch(existing ? `${base}/${existing.id}` : base, {
    method: existing ? "PUT" : "POST",
    headers,
    body
  })
  const result = await response.json()
  if (!result.success) throw new Error(`DNS ${type} ${hostname}: ${JSON.stringify(result.errors)}`)
  console.log(`DNS ${type} ${hostname} -> ${content}`)
}

const id = process.argv[2]
const { org, relays } = await readRelays()
const relay = relays.find((entry) => entry.id === id)
if (relay === undefined) throw new Error(`unknown relay ${id}`)
const app = `codevisor-${relay.id}`
await ensureApp(app, org)
const ips = await ensureIps(app)
await ensureVolume(app, relay.region)
await fly(
  "secrets",
  "set",
  `RELAY_AUTHORIZE_TOKEN=${required("RELAY_AUTHORIZE_TOKEN")}`,
  "--stage",
  "-a",
  app
)
if (ips.v4) await ensureDns(relay.hostname, "A", ips.v4)
if (ips.v6) await ensureDns(relay.hostname, "AAAA", ips.v6)
console.log(`${app} provisioned (${relay.hostname})`)
