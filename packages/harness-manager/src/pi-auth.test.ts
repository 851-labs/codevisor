import type { AuthInteraction, OAuthCredential, Provider } from "@earendil-works/pi-ai"
import { mkdtempSync, readFileSync, rmSync, statSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterEach, describe, expect, it } from "vitest"
import { makePiAuthManager } from "./pi-auth.js"

const directories: string[] = []

const waitFor = async (predicate: () => boolean): Promise<void> => {
  for (let attempt = 0; attempt < 50; attempt += 1) {
    if (predicate()) return
    await new Promise((resolve) => setTimeout(resolve, 10))
  }
  throw new Error("Timed out waiting for Pi authentication")
}

afterEach(() => {
  for (const directory of directories.splice(0)) {
    rmSync(directory, { force: true, recursive: true })
  }
})

describe("Pi provider authentication", () => {
  it("manages Pi's auth.json through a native prompt flow", async () => {
    const home = mkdtempSync(join(tmpdir(), "codevisor-pi-providers-"))
    directories.push(home)
    const manager = makePiAuthManager({ resolveEnv: () => Promise.resolve({ HOME: home }) })

    const providers = await manager.providers()
    expect(providers).toContainEqual(
      expect.objectContaining({ id: "openai", name: "OpenAI", methods: ["api_key"] })
    )

    const started = await manager.beginLogin("openai", "api_key")
    expect(started).toMatchObject({
      providerId: "openai",
      state: "waiting",
      prompt: { type: "secret", message: "Enter OpenAI API key" }
    })

    const completed = await manager.answer(started.id, "sk-test-native-pi")
    expect(completed.state).toBe("complete")

    const authPath = join(home, ".pi", "agent", "auth.json")
    expect(JSON.parse(readFileSync(authPath, "utf8"))).toEqual({
      openai: { type: "api_key", key: "sk-test-native-pi" }
    })
    expect(statSync(authPath).mode & 0o777).toBe(0o600)
    expect((await manager.providers()).find((provider) => provider.id === "openai")).toMatchObject({
      credentialType: "api_key"
    })

    await manager.logout("openai")
    expect(JSON.parse(readFileSync(authPath, "utf8"))).toEqual({})
  })

  it("completes while a manual-code fallback is visible when the browser callback wins", async () => {
    const home = mkdtempSync(join(tmpdir(), "codevisor-pi-callback-"))
    directories.push(home)
    let completeCallback: (() => void) | undefined
    const provider = {
      id: "callback-provider",
      name: "Callback Provider",
      auth: {
        oauth: {
          name: "Callback OAuth",
          login: async (interaction: AuthInteraction) => {
            const promptAbort = new AbortController()
            interaction.notify({
              type: "auth_url",
              url: "https://example.com/sign-in",
              instructions: "Complete login in your browser."
            })
            void interaction
              .prompt({
                type: "manual_code",
                message: "Paste the redirect URL as a fallback:",
                signal: promptAbort.signal
              })
              .catch(() => undefined)
            await new Promise<void>((resolve) => {
              completeCallback = resolve
            })
            promptAbort.abort()
            return {
              type: "oauth" as const,
              access: "access-token",
              refresh: "refresh-token",
              expires: Date.now() + 3_600_000
            }
          },
          refresh: async (credential: OAuthCredential) => credential,
          toAuth: async (credential: OAuthCredential) => ({ apiKey: credential.access })
        }
      },
      getModels: () => []
    } as unknown as Provider
    const manager = makePiAuthManager({
      providers: [provider],
      resolveEnv: () => Promise.resolve({ HOME: home })
    })

    const started = await manager.beginLogin(provider.id, "oauth")
    expect(started).toMatchObject({
      state: "waiting",
      prompt: { type: "manual_code" },
      event: { type: "auth_url" }
    })

    completeCallback?.()
    await waitFor(() => manager.flow(started.id).state === "complete")
    expect(JSON.parse(readFileSync(join(home, ".pi", "agent", "auth.json"), "utf8"))).toEqual({
      "callback-provider": expect.objectContaining({ type: "oauth", access: "access-token" })
    })
  })
})
