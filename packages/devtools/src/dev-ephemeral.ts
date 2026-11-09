import { createReadStream } from "node:fs"
import { readdir, stat } from "node:fs/promises"
import { createServer, type Server } from "node:http"
import { join } from "node:path"

export interface EphemeralArtifactsServer {
  readonly server: Server
  readonly url: string
}

const archivePattern = /^codevisor-server-[a-z0-9-]+\.tar\.gz(\.sha256)?$/

export async function serveDevEphemeralArtifacts(options: {
  readonly repoRoot: string
  readonly archiveRoot: string
  readonly host: string
}): Promise<EphemeralArtifactsServer> {
  const files = await artifactFiles(options.repoRoot, options.archiveRoot)
  const server = createServer((request, response) => {
    const path = request.method === "GET" ? files.get(pathnameOf(request.url)) : undefined
    if (path === undefined) {
      response.writeHead(404).end()
      return
    }
    response.writeHead(200, { "content-type": "application/octet-stream" })
    createReadStream(path)
      .on("error", () => response.destroy())
      .pipe(response)
  })
  const port = await listen(server, options.host)
  return { server, url: `http://${options.host}:${port}` }
}

export function devEphemeralEnvironment(options: {
  readonly artifactsUrl: string
  readonly vmHost: string
  readonly cloudPort: number
  readonly appBundle: string
}): Record<string, string> {
  return {
    CODEVISOR_DEV_EPHEMERAL_ARTIFACTS_URL: options.artifactsUrl,
    CODEVISOR_DEV_EPHEMERAL_CLOUD_URL: `http://${options.vmHost}:${options.cloudPort}`,
    CODEVISOR_EPHEMERAL_APP_PATH: options.appBundle
  }
}

async function artifactFiles(repoRoot: string, archiveRoot: string): Promise<Map<string, string>> {
  const files = new Map([["/install.sh", join(repoRoot, "apps/www/public/install.sh")]])
  for (const name of await readdir(archiveRoot).catch(() => [])) {
    const path = join(archiveRoot, name)
    if (archivePattern.test(name) && (await stat(path)).isFile()) files.set(`/${name}`, path)
  }
  return files
}

function listen(server: Server, host: string): Promise<number> {
  return new Promise((resolve, reject) => {
    server.once("error", reject)
    server.listen(0, host, () => {
      const address = server.address()
      if (address === null || typeof address === "string")
        reject(new Error("expected a TCP address"))
      else resolve(address.port)
    })
  })
}

function pathnameOf(url: string | undefined): string {
  return new URL(url ?? "/", "http://artifacts.invalid").pathname
}
