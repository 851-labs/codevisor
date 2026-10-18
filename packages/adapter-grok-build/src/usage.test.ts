import type { AcpAgentConnection, AcpConnector } from "@codevisor/adapter-acp"
import {
  AgentRuntimeError,
  harnessCatalog,
  type ProviderEnvironment
} from "@codevisor/agent-runtime"
import { Effect } from "effect"
import { describe, expect, it } from "vitest"

import { makeGrokBuildProvider } from "./provider.js"

const environment: ProviderEnvironment = {
  env: { PATH: "/bin" },
  envFor: () => Promise.resolve(environment.env),
  executableExists: (name) => name === "grok",
  locateExecutable: (name) => (name === "grok" ? "/bin/grok" : undefined)
}
const definition = harnessCatalog.find((candidate) => candidate.id === "grok-build")!

const unused = () => Effect.die(new Error("not used by usage reads"))

const unusedConnection: AcpAgentConnection = {
  createSession: unused,
  loadSession: unused,
  prompt: unused,
  cancel: unused,
  setMode: unused,
  setConfigOption: unused,
  probeAuth: unused,
  authenticate: unused,
  logout: unused(),
  close: unused()
}

const providerAnswering = (
  answer: (method: string) => Effect.Effect<unknown, AgentRuntimeError>,
  onProbe: () => void = () => undefined,
  providedSignIn = true
) => {
  const requests: Array<string> = []
  let closed = 0
  let probed = 0
  const authenticated: Array<string> = []
  const connector: AcpConnector = {
    connect: () =>
      Effect.succeed<AcpAgentConnection>({
        ...unusedConnection,
        probeAuth: () =>
          Effect.sync(() => {
            probed += 1
            onProbe()
            return {
              state: "unauthenticated" as const,
              methods: [
                { id: "browser", name: "Grok" },
                ...(providedSignIn ? [{ id: "grok.com", name: "Codevisor", external: true }] : [])
              ],
              canLogout: false
            }
          }),
        authenticate: (methodId) =>
          Effect.sync(() => {
            authenticated.push(methodId)
            onProbe()
          }),
        extRequest: (method) => {
          requests.push(method)
          return answer(method)
        },
        close: Effect.sync(() => {
          closed += 1
        })
      })
  }
  return {
    provider: makeGrokBuildProvider(environment, { connector }),
    requests,
    closed: () => closed,
    probes: () => probed,
    authenticated
  }
}

describe("Grok Build usage limits", () => {
  it("reads the credit allowance from Grok's billing extension", async () => {
    const { provider, requests, closed } = providerAnswering(() =>
      Effect.succeed({
        config: {
          creditUsagePercent: 37.5,
          currentPeriod: { type: "USAGE_PERIOD_TYPE_WEEKLY", end: "2026-10-25T00:00:00Z" },
          prepaidBalance: { val: 1250 },
          history: []
        },
        subscription_tier: "SuperGrok Heavy"
      })
    )

    const limits = await Effect.runPromise(provider.readUsageLimits!(definition, "/project"))

    expect(requests).toEqual(["_x.ai/billing"])
    expect(closed()).toBe(1)
    expect(limits).toMatchObject({
      harnessId: "grok-build",
      plan: "SuperGrok Heavy",
      state: "available",
      windows: [
        {
          id: "credits",
          label: "Weekly credits",
          resetsAt: "2026-10-25T00:00:00.000Z",
          usedPercent: 37.5
        }
      ],
      credits: { balance: "$12.50", hasCredits: true, unlimited: false }
    })
  })

  it("falls back to the legacy monthly budget fields", async () => {
    const { provider } = providerAnswering(() =>
      Effect.succeed({
        config: {
          monthlyLimit: { val: 2000 },
          used: { val: 500 },
          billingPeriodEnd: "2026-11-01T00:00:00Z"
        }
      })
    )

    expect(
      await Effect.runPromise(provider.readUsageLimits!(definition, "/project"))
    ).toMatchObject({
      state: "available",
      windows: [{ label: "Credits", usedPercent: 25, resetsAt: "2026-11-01T00:00:00.000Z" }]
    })
  })

  it("signs Grok in with Codevisor's credentials before asking again for billing", async () => {
    let signedIn = false
    const { provider, requests, probes, authenticated } = providerAnswering(
      () =>
        signedIn
          ? Effect.succeed({ config: { creditUsagePercent: 5 } })
          : Effect.fail(
              new AgentRuntimeError({ message: "Authentication required", operation: "extRequest" })
            ),
      () => {
        signedIn = authenticated.length > 0
      }
    )

    expect(
      await Effect.runPromise(provider.readUsageLimits!(definition, "/project"))
    ).toMatchObject({
      state: "available",
      windows: [{ usedPercent: 5 }]
    })
    expect(requests).toEqual(["_x.ai/billing", "_x.ai/billing"])
    expect(probes()).toBe(1)
    expect(authenticated).toEqual(["grok.com"])
  })

  it("reports a refused billing request as unavailable and still closes Grok", async () => {
    const { provider, closed, authenticated } = providerAnswering(
      () =>
        Effect.fail(
          new AgentRuntimeError({ message: "Authentication required", operation: "extRequest" })
        ),
      () => undefined,
      false
    )

    expect(
      await Effect.runPromise(provider.readUsageLimits!(definition, "/project"))
    ).toMatchObject({
      detail: "Authentication required",
      state: "unavailable",
      windows: []
    })
    expect(closed()).toBe(1)
    expect(authenticated).toEqual([])
  })
})
