type Access = "none" | "read" | "write"

interface Route {
  readonly needs: Exclude<Access, "none">
  readonly respond: (request: Request, env: Env) => Promise<Response>
}

const artifactPath = /^\/v8\/artifacts\/([0-9A-Za-z_-]{1,128})$/
const teamName = /^[0-9A-Za-z_.-]{1,64}$/
const durationHeader = "x-artifact-duration"
const tagHeader = "x-artifact-tag"

export default {
  fetch: (request, env) => handle(request, env)
} satisfies ExportedHandler<Env>

async function handle(request: Request, env: Env): Promise<Response> {
  const route = routeFor(request)
  if (route === undefined) return problem(404, "not found")

  const access = await accessOf(request, env)
  if (!grants(access, route.needs)) return problem(401, "unauthorized")

  return route.respond(request, env)
}

function routeFor(request: Request): Route | undefined {
  const url = new URL(request.url)
  if (url.pathname === "/v8/artifacts/status") return readRoute(() => json({ status: "enabled" }))
  if (url.pathname === "/v8/artifacts/events") return readRoute(() => json({}))

  const hash = artifactPath.exec(url.pathname)?.[1]
  const team = teamOf(url)
  if (hash === undefined || team === undefined) return undefined

  return artifactRoute(request.method, `${team}/${hash}`)
}

function artifactRoute(method: string, key: string): Route | undefined {
  if (method === "GET") return { needs: "read", respond: (_, env) => readArtifact(env, key) }
  if (method === "HEAD") return { needs: "read", respond: (_, env) => describeArtifact(env, key) }
  if (method === "PUT")
    return { needs: "write", respond: (request, env) => storeArtifact(request, env, key) }
  return undefined
}

function readRoute(respond: () => Response): Route {
  return { needs: "read", respond: async () => respond() }
}

function teamOf(url: URL): string | undefined {
  const team = url.searchParams.get("slug") ?? url.searchParams.get("teamId") ?? "default"
  return teamName.test(team) ? team : undefined
}

async function readArtifact(env: Env, key: string): Promise<Response> {
  const artifact = await env.ARTIFACTS.get(key)
  if (artifact === null) return problem(404, "artifact not found")

  return new Response(artifact.body, { headers: artifactHeaders(artifact) })
}

async function describeArtifact(env: Env, key: string): Promise<Response> {
  const artifact = await env.ARTIFACTS.head(key)
  if (artifact === null) return new Response(null, { status: 404 })

  return new Response(null, { headers: artifactHeaders(artifact) })
}

async function storeArtifact(request: Request, env: Env, key: string): Promise<Response> {
  if (request.body === null || request.headers.get("content-length") === null) {
    return problem(411, "artifact uploads need a Content-Length")
  }

  await env.ARTIFACTS.put(key, request.body, {
    httpMetadata: { contentType: "application/octet-stream" },
    customMetadata: uploadedMetadata(request)
  })
  return json({ urls: [] }, 202)
}

function uploadedMetadata(request: Request): Record<string, string> {
  const metadata: Record<string, string> = {}
  for (const header of [durationHeader, tagHeader]) {
    const value = request.headers.get(header)
    if (value !== null) metadata[header] = value
  }
  return metadata
}

function artifactHeaders(artifact: R2Object): Headers {
  const headers = new Headers({
    "content-type": "application/octet-stream",
    "content-length": String(artifact.size)
  })
  for (const [name, value] of Object.entries(artifact.customMetadata ?? {}))
    headers.set(name, value)
  return headers
}

async function accessOf(request: Request, env: Env): Promise<Access> {
  const token = bearerToken(request)
  if (token === undefined) return "none"
  if (await sameSecret(token, env.TURBO_TOKEN)) return "write"

  return (await sameSecret(token, env.TURBO_READ_TOKEN)) ? "read" : "none"
}

function grants(access: Access, needs: Route["needs"]): boolean {
  return access === "write" || access === needs
}

function bearerToken(request: Request): string | undefined {
  const header = request.headers.get("authorization") ?? ""
  const [scheme, token] = header.split(" ")
  return scheme === "Bearer" && token !== undefined && token !== "" ? token : undefined
}

async function sameSecret(given: string, expected: string): Promise<boolean> {
  if (expected === "") return false

  const [a, b] = await Promise.all([digest(given), digest(expected)])
  return crypto.subtle.timingSafeEqual(a, b)
}

function digest(value: string): Promise<ArrayBuffer> {
  return crypto.subtle.digest("SHA-256", new TextEncoder().encode(value))
}

function json(body: unknown, status = 200): Response {
  return Response.json(body, { status })
}

function problem(status: number, message: string): Response {
  return json({ error: { message } }, status)
}
