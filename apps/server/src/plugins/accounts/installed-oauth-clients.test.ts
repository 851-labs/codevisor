import { chmod, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"

import { describe, expect, it, onTestFinished } from "vitest"

import { installedClientSources, installedOAuthClients } from "./installed-oauth-clients.js"

const googleClient = (clientId: string, clientSecret?: string) => ({
  installed: {
    client_id: clientId,
    ...(clientSecret === undefined ? {} : { client_secret: clientSecret }),
    redirect_uris: ["http://localhost"]
  }
})

const temporaryRoot = async (): Promise<string> => {
  const root = await mkdtemp(join(tmpdir(), "installed-oauth-"))
  onTestFinished(() => rm(root, { recursive: true, force: true }))
  return root
}

const writeClient = async (path: string, contents: unknown): Promise<string> => {
  await mkdir(dirname(path), { recursive: true })
  await writeFile(path, typeof contents === "string" ? contents : JSON.stringify(contents))
  await chmod(path, 0o600)
  return path
}

const google = installedClientSources.get("google")!

const layout = async () => {
  const root = await temporaryRoot()
  const home = join(root, "home")
  const runtimeRoot = join(root, "runtime")
  return {
    home,
    runtimeRoot,
    devFile: join(home, google.devFile),
    bundledFile: join(runtimeRoot, google.bundledFile),
    clients: (env: NodeJS.ProcessEnv, dev: boolean) =>
      installedOAuthClients({ env, dev, home, runtimeRoot })
  }
}

describe("installed OAuth clients", () => {
  it("reads Google's client file from the dev secrets folder in dev instances", async () => {
    const paths = await layout()
    await writeClient(paths.devFile, googleClient("dev-client", "dev-secret"))

    const client = await paths.clients({}, true)("google")

    expect(client).toEqual({ clientId: "dev-client", clientSecret: "dev-secret" })
  })

  it("uses the client a release build bundled, in any build and ahead of the dev file", async () => {
    const paths = await layout()
    await writeClient(paths.devFile, googleClient("dev-client"))
    await writeClient(paths.bundledFile, googleClient("bundled-client", "bundled-secret"))

    const release = await paths.clients({}, false)("google")
    const dev = await paths.clients({}, true)("google")

    expect(release).toEqual({ clientId: "bundled-client", clientSecret: "bundled-secret" })
    expect(dev).toEqual(release)
  })

  it("prefers the file the environment points to, and falls back when it's unusable", async () => {
    const paths = await layout()
    await writeClient(paths.bundledFile, googleClient("bundled-client"))
    const configured = await writeClient(join(paths.home, "prod.json"), googleClient("prod-client"))
    const broken = await writeClient(join(paths.home, "broken.json"), "{")

    const fromEnv = await paths.clients(
      { CODEVISOR_GOOGLE_OAUTH_CLIENT_FILE: configured },
      false
    )("google")
    const fallback = await paths.clients(
      { CODEVISOR_GOOGLE_OAUTH_CLIENT_FILE: broken },
      false
    )("google")

    expect(fromEnv).toEqual({ clientId: "prod-client" })
    expect(fallback).toEqual({ clientId: "bundled-client" })
  })

  it("has no client in release builds without configuration, or for unknown providers", async () => {
    const paths = await layout()
    await writeClient(paths.devFile, googleClient("dev-client"))

    const release = paths.clients({ CODEVISOR_GOOGLE_OAUTH_CLIENT_FILE: "" }, false)
    const dev = paths.clients({}, true)

    expect(await release("google")).toBeUndefined()
    expect(await dev("slack")).toBeUndefined()
    expect(await dev("constructor")).toBeUndefined()
  })

  it.each([
    { name: "a missing file", contents: undefined },
    { name: "a file that isn't JSON", contents: "{" },
    { name: "a web client", contents: { web: { client_id: "web" } } },
    { name: "an empty client id", contents: { installed: { client_id: "" } } }
  ])("has no client for $name", async ({ contents }) => {
    const paths = await layout()
    if (contents !== undefined) await writeClient(paths.devFile, contents)

    expect(await paths.clients({}, true)("google")).toBeUndefined()
  })
})
