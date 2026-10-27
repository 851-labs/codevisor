import { mkdir, mkdtemp, rm, utimes, writeFile } from "node:fs/promises"
import { createServer, type Server } from "node:http"
import type { AddressInfo } from "node:net"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach, describe, expect, it } from "vitest"

import {
  appBundleOf,
  preinstalledAgentCommands,
  STABLE_SERVER_MANIFEST_URL,
  tartImages
} from "./ephemeral-image.js"

const created: string[] = []

afterEach(async () => {
  await Promise.all(created.splice(0).map((path) => rm(path, { recursive: true, force: true })))
})

const fakeApp = async (): Promise<string> => {
  const root = await mkdtemp(join(tmpdir(), "codevisor-image-"))
  created.push(root)
  const app = join(root, "Codevisor (dev).app")
  await mkdir(join(app, "Contents", "_CodeSignature"), { recursive: true })
  await mkdir(join(app, "Contents", "MacOS"), { recursive: true })
  await writeFile(join(app, "Contents", "_CodeSignature", "CodeResources"), "<plist/>")
  await writeFile(join(app, "Contents", "MacOS", "Codevisor (dev)"), "binary-1")
  return app
}

const serverIdentity = (body: string) => () => Promise.resolve(body)

describe("Tart image recipe", () => {
  it("has no image to prepare when there is no app to install", async () => {
    const images = tartImages({ appPath: undefined, serverIdentityUrl: STABLE_SERVER_MANIFEST_URL })

    expect(await images.recipe()).toBeUndefined()
  })

  it("installs a release app with the stable server and the common agent CLIs", async () => {
    const appPath = await fakeApp()
    const urls: string[] = []
    const images = tartImages({ appPath, serverIdentityUrl: STABLE_SERVER_MANIFEST_URL }, (url) => {
      urls.push(url)
      return Promise.resolve('{"version":"0.1.109"}')
    })

    expect(await images.recipe()).toEqual({
      appPath,
      fingerprint: expect.stringMatching(/^[0-9a-f]{64}$/),
      agentCommands: preinstalledAgentCommands()
    })
    expect(urls).toEqual([STABLE_SERVER_MANIFEST_URL])
    expect(preinstalledAgentCommands()).toEqual(
      expect.arrayContaining(["brew install --cask codex", "npm install -g @google/gemini-cli"])
    )
    expect(preinstalledAgentCommands(["codex", "retired-agent"])).toEqual([
      "brew install --cask codex"
    ])
  })

  it("prepares a new image when the app or the server changes, and launches a dev app as a dev build", async () => {
    const appPath = await fakeApp()
    const settings = {
      appPath,
      serverIdentityUrl: "http://192.168.1.2:4000/codevisor-server-darwin-arm64.tar.gz.sha256",
      installUrl: "http://192.168.1.2:4000/install.sh",
      installEnvironment: { CODEVISOR_VERSION: "dev" },
      developmentInstance: "apricot-ephemeral"
    }
    const first = await tartImages(settings, serverIdentity("aaa")).recipe()
    const newServer = await tartImages(settings, serverIdentity("bbb")).recipe()
    const executable = join(appPath, "Contents", "MacOS", "Codevisor (dev)")
    await utimes(executable, new Date(0), new Date(0))
    const resigned = await tartImages(settings, serverIdentity("aaa")).recipe()
    await writeFile(executable, "binary-2")
    const newApp = await tartImages(settings, serverIdentity("aaa")).recipe()

    expect(first).toMatchObject({
      installUrl: settings.installUrl,
      installEnvironment: settings.installEnvironment,
      development: { instanceId: "apricot-ephemeral", serverPort: 49361 }
    })
    expect(resigned?.fingerprint).toBe(first?.fingerprint)
    expect(new Set([first?.fingerprint, newServer?.fingerprint, newApp?.fingerprint]).size).toBe(3)
  })

  it("reads the server identity over HTTP and refuses a missing one", async () => {
    const appPath = await fakeApp()
    const { server, port } = await listening((url) =>
      url === "/server.sha256" ? "abc123" : undefined
    )
    const base = `http://127.0.0.1:${port}`
    try {
      const found = tartImages({ appPath, serverIdentityUrl: `${base}/server.sha256` })
      const missing = tartImages({ appPath, serverIdentityUrl: `${base}/gone` })

      expect((await found.recipe())?.fingerprint).toMatch(/^[0-9a-f]{64}$/)
      await expect(missing.recipe()).rejects.toThrow(`Could not read ${base}/gone (HTTP 404)`)
    } finally {
      await new Promise((resolve) => server.close(resolve))
    }
  })

  it("finds the app bundle a release server runs from", () => {
    expect(appBundleOf("/Applications/Codevisor.app/Contents/Resources/server/bin/node")).toBe(
      "/Applications/Codevisor.app"
    )
    expect(appBundleOf("/opt/homebrew/bin/node")).toBeUndefined()
  })
})

interface Listening {
  readonly server: Server
  readonly port: number
}

const listening = (body: (url: string | undefined) => string | undefined): Promise<Listening> =>
  new Promise((resolve) => {
    const server = createServer((request, response) => {
      const text = body(request.url)
      if (text === undefined) response.writeHead(404).end()
      else response.writeHead(200).end(text)
    })
    server.listen(0, "127.0.0.1", () => resolve({ server, port: portOf(server.address()) }))
  })

const portOf = (address: string | AddressInfo | null): number =>
  typeof address === "object" && address !== null ? address.port : 0
