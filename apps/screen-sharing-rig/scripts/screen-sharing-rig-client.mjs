/// HTTP access to the rig processes: the viewer's loopback control port and the host's LAN port,
/// both bearer-token gated. Pure of process state; the CLI passes the local viewer config in.
export async function http(method, url, token, body) {
  const init = {
    method,
    headers: { Authorization: `Bearer ${token}` },
    signal: AbortSignal.timeout(body?.seconds ? (body.seconds + 15) * 1000 : 5000)
  }
  if (body) {
    init.headers["Content-Type"] = "application/json"
    init.body = JSON.stringify(body)
  }
  const response = await fetch(url, init)
  const text = await response.text()
  let parsed
  try {
    parsed = JSON.parse(text)
  } catch {
    parsed = { error: text }
  }
  if (!response.ok)
    throw new Error(`${method} ${url} → ${response.status}: ${parsed.error ?? text}`)
  return parsed
}

export function endpointsFor(config) {
  if (config.role !== "viewer")
    throw new Error("This Mac's rig is not the viewer; status runs from the viewer.")
  return {
    token: config.token,
    viewer: `http://127.0.0.1:${config.controlPort ?? 48732}`,
    host: `http://${config.peer.includes(":") ? config.peer : `${config.peer}:${config.port ?? 48731}`}`
  }
}

export function summarize(status) {
  const build = status.build
    ? `${status.build.commit.slice(0, 8)}${status.build.dirty ? "*" : ""} ${status.build.configuration}`
    : "?"
  return `${status.role.padEnd(6)} ${status.name} · ${build} · ${status.connection} · session ${status.sessionID ?? "-"} · reconnects ${status.reconnects} · up ${Math.round(status.uptimeSeconds)}s${status.capture ? ` · ${status.capture}` : ""}`
}
