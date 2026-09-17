import { existsSync, mkdtempSync, readFileSync, rmSync, statSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { AuthInteraction, OAuthCredential, Provider } from "@earendil-works/pi-ai"
import { afterEach, describe, expect, it, vi } from "vitest"

import { makePiAuthManager, piAuthPath } from "./pi-auth.js"

const directories: string[] = []

afterEach(() => {
  for (const directory of directories.splice(0)) {
    rmSync(directory, { force: true, recursive: true })
  }
})

describe("Pi provider authentication", () => {
  it("saves a managed login before completing and never writes its refresh token to the native file", async () => {
    const home = mkdtempSync(join(tmpdir(), "codevisor-pi-managed-"))
    directories.push(home)
    const credential = { type: "oauth", access: "access", refresh: "refresh", expires: 3_600_000 }
    const provider = {
      id: "test",
      name: "Test",
      auth: {
        oauth: {
          login: async () => credential,
          refresh: async () => credential,
          toAuth: async () => ({ apiKey: "access" })
        }
      },
      getModels: () => []
    } as unknown as Provider
    const saved = Promise.withResolvers<boolean>()
    const called = Promise.withResolvers<void>()
    const completed = Promise.withResolvers<void>()
    const saveCredential = vi.fn(async () => {
      called.resolve()
      return saved.promise
    })
    const manager = makePiAuthManager({
      resolveEnv: async () => ({ HOME: home }),
      providers: [provider],
      saveCredential,
      onFlowChanged: (flow) => {
        if (flow.state === "complete") completed.resolve()
      }
    })
    const pending = manager.beginLogin("test", "oauth", true)
    await called.promise
    expect(saveCredential).toHaveBeenCalledWith("test", credential, true)
    expect(existsSync(piAuthPath({ HOME: home }))).toBe(false)
    saved.resolve(true)
    await pending
    await completed.promise
    expect(existsSync(piAuthPath({ HOME: home }))).toBe(false)
    expect(piAuthPath({ HOME: home, PI_CODING_AGENT_DIR: " ~/custom " })).toBe(
      join(home, "custom", "auth.json")
    )
  })

  it("reports a vault failure without saving or completing the login", async () => {
    const home = mkdtempSync(join(tmpdir(), "codevisor-pi-failed-"))
    directories.push(home)
    const finished = Promise.withResolvers<void>()
    const manager = makePiAuthManager({
      resolveEnv: async () => ({ HOME: home }),
      saveCredential: async () => {
        throw new Error("Unable to save account")
      },
      onFlowChanged: (flow) => {
        if (flow.state === "error") finished.resolve()
      }
    })
    const flow = await manager.beginLogin("openai", "api_key")
    await manager.answer(flow.id, "fixture-key")
    await finished.promise
    expect(manager.flow(flow.id).state).toBe("error")
    expect(existsSync(piAuthPath({ HOME: home }))).toBe(false)
  })

  it("manages Pi's auth.json through a native prompt flow", async () => {
    const home = mkdtempSync(join(tmpdir(), "codevisor-pi-providers-"))
    directories.push(home)
    const completedFlow = Promise.withResolvers<void>()
    const manager = makePiAuthManager({
      resolveEnv: () => Promise.resolve({ HOME: home }),
      onFlowChanged: (flow) => {
        if (flow.state === "complete") completedFlow.resolve()
      }
    })

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

    await manager.answer(started.id, "sk-test-native-pi")
    await completedFlow.promise
    const completed = manager.flow(started.id)
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
    const completedFlow = Promise.withResolvers<void>()
    const manager = makePiAuthManager({
      onFlowChanged: (flow) => {
        if (flow.state === "complete") completedFlow.resolve()
      },
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
    await completedFlow.promise
    expect(JSON.parse(readFileSync(join(home, ".pi", "agent", "auth.json"), "utf8"))).toEqual({
      "callback-provider": expect.objectContaining({ type: "oauth", access: "access-token" })
    })
  })
})
