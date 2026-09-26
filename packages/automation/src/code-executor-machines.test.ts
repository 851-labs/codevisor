import { describe, expect, it } from "vitest"

import {
  CodeExecutionToolError,
  makeCodeExecutor,
  type CodeToolCall,
  type ExecuteCodeOptions
} from "./code-executor.js"

const roster = {
  machines: [
    { id: "studio", name: "Mac Studio", online: true, isCurrent: true },
    { id: "mbp-1", name: "MacBook Pro", online: true, isCurrent: false },
    { id: "mbp-2", name: "MacBook Air", online: false, isCurrent: false }
  ]
}

const context: ExecuteCodeOptions["context"] = {
  machine: { id: "studio", name: "Mac Studio" },
  originClientId: "window-2"
}

/// Runs `code` against a scripted host: `respond` answers each call.
const execute = async (
  code: string,
  respond: (call: CodeToolCall) => unknown,
  options: ExecuteCodeOptions = { context }
) => {
  const calls: Array<CodeToolCall> = []
  const result = await makeCodeExecutor().execute(
    code,
    {
      invoke: async (call) => {
        calls.push(call)
        return respond(call)
      }
    },
    options
  )
  return { calls, result }
}

describe.sequential("sandbox machines, clients, status, and typed errors", () => {
  it("resolves machines by id, name, or prefix and routes their tools to that machine", async () => {
    const { calls, result } = await execute(
      `async () => {
        const byPrefix = await machines.get("macbook p");
        const built = await byPrefix.tools.xcode.build({ scheme: "App" });
        const described = await byPrefix.tools.describe.tool({ path: "xcode.build" });
        const byId = await machines.get("mbp-2");
        const current = await machines.get("mac studio");
        const failures = [];
        for (const query of ["macbook", "nope"]) {
          await machines.get(query).catch((error) => failures.push(error.message));
        }
        return {
          built, described, byId: byId.name, failures,
          currentIsTools: current.tools === tools && machines.current.tools === tools,
          current: machines.current,
          listed: await machines.list()
        };
      }`,
      (call) =>
        call.path === "codevisor.machines.list" ? roster : { ran: call.path, on: call.target }
    )

    expect(result.error).toBeUndefined()
    expect(result.result).toEqual({
      built: { ran: "xcode.build", on: { machine: "mbp-1", machineName: "MacBook Pro" } },
      described: { ran: "describe.tool", on: { machine: "mbp-1", machineName: "MacBook Pro" } },
      byId: "MacBook Air",
      failures: [
        '"macbook" matches several machines: MacBook Pro (mbp-1), MacBook Air (mbp-2). Pass a machine id.',
        'No machine matches "nope". Machines: Mac Studio (studio), MacBook Pro (mbp-1), MacBook Air (mbp-2)'
      ],
      currentIsTools: true,
      // Handles serialize to their facts; tools and clients stay attached.
      current: { id: "studio", name: "Mac Studio", isCurrent: true },
      listed: roster.machines
    })
    expect(calls.find((call) => call.path === "xcode.build")).toEqual({
      path: "xcode.build",
      args: { scheme: "App" },
      target: { machine: "mbp-1", machineName: "MacBook Pro" }
    })
    // Lookups machines.get makes for the script are marked internal and stay
    // on this machine; the script's own machines.list() is a plain call.
    expect(
      calls.filter((call) => call.path === "codevisor.machines.list").map((call) => call.target)
    ).toEqual([
      { internal: true },
      { internal: true },
      { internal: true },
      { internal: true },
      { internal: true },
      undefined
    ])
  })

  it("lists clients with their origin and binds each client's controls to its id and machine", async () => {
    const { calls, result } = await execute(
      `async () => {
        const local = await clients.list();
        const origin = local.find((client) => client.isOrigin);
        await origin.navigate({ workspaceId: "w" });
        await origin.layout({ action: "new_tab" });
        await origin.openPage({ page: "home" });
        await origin.window({ action: "focus" });
        await origin.context();
        const remote = await (await machines.get("mbp-1")).clients.list();
        await remote[0].navigate({ workspaceId: "r" });
        return { local, remote };
      }`,
      (call) => {
        if (call.path === "codevisor.machines.list") return roster
        if (call.path === "codevisor.clients.list" && call.target === undefined) {
          return [
            { clientId: "window-1", name: "Studio main", platform: "macos" },
            { clientId: "window-2", name: "Studio side", platform: "macos" }
          ]
        }
        if (call.path === "codevisor.clients.list") {
          return { clients: [{ id: "phone", name: "iPhone", platform: "ios", isOrigin: false }] }
        }
        return {}
      }
    )

    expect(result.error).toBeUndefined()
    const studio = { id: "studio", name: "Mac Studio" }
    expect(result.result).toEqual({
      local: [
        {
          clientId: "window-1",
          id: "window-1",
          name: "Studio main",
          platform: "macos",
          machine: studio,
          isOrigin: false
        },
        {
          clientId: "window-2",
          id: "window-2",
          name: "Studio side",
          platform: "macos",
          machine: studio,
          isOrigin: true
        }
      ],
      remote: [
        {
          id: "phone",
          name: "iPhone",
          platform: "ios",
          isOrigin: false,
          machine: { id: "mbp-1", name: "MacBook Pro" }
        }
      ]
    })
    const remoteTarget = { machine: "mbp-1", machineName: "MacBook Pro" }
    expect(
      calls
        .filter((call) => call.path !== "codevisor.machines.list")
        .map(({ path, args, target }) => [path, args, target])
    ).toEqual([
      ["codevisor.clients.list", {}, undefined],
      ["codevisor.clients.navigate", { workspaceId: "w", clientId: "window-2" }, undefined],
      ["codevisor.clients.layout", { action: "new_tab", clientId: "window-2" }, undefined],
      ["codevisor.clients.open_page", { clientId: "window-2", body: { page: "home" } }, undefined],
      ["codevisor.clients.window", { clientId: "window-2", body: { action: "focus" } }, undefined],
      ["codevisor.clients.context", { clientId: "window-2" }, undefined],
      ["codevisor.clients.list", {}, remoteTarget],
      ["codevisor.clients.navigate", { workspaceId: "r", clientId: "phone" }, remoteTarget]
    ])
  })

  it("searches every online machine and tags each match with its machine", async () => {
    const { calls, result } = await execute(
      `async () => ({
        all: await tools.search({ query: "build", machines: "all", limit: 2 }),
        local: await tools.search({ query: "build" })
      })`,
      (call) => {
        if (call.path === "codevisor.machines.list") return roster
        if (call.target === undefined) {
          return { items: [{ path: "local.build", score: 10 }], total: 1 }
        }
        throw new CodeExecutionToolError("MacBook Pro search failed")
      }
    )

    expect(result.error).toBeUndefined()
    expect(result.result).toEqual({
      all: {
        items: [{ path: "local.build", score: 10, machine: { id: "studio", name: "Mac Studio" } }],
        total: 1,
        unavailable: [
          { machine: { id: "mbp-1", name: "MacBook Pro" }, error: "MacBook Pro search failed" },
          { machine: { id: "mbp-2", name: "MacBook Air" }, error: "offline" }
        ],
        workflow: expect.stringContaining("machines.get(item.machine.id)")
      },
      local: { items: [{ path: "local.build", score: 10 }], total: 1 }
    })
    // The scope never reaches a host search, and offline machines are skipped.
    expect(
      calls.filter((call) => call.path === "search").map(({ args, target }) => [args, target])
    ).toEqual([
      [{ query: "build", limit: 2 }, undefined],
      [
        { query: "build", limit: 2 },
        { machine: "mbp-1", machineName: "MacBook Pro" }
      ],
      [{ query: "build" }, undefined]
    ])
  })

  it("rethrows coded tool failures as named error classes and still masks internal failures", async () => {
    const { result } = await execute(
      `async () => {
        const describe = (error) => ({
          name: error.name,
          message: error.message,
          code: error.code,
          details: error.details,
          machineId: error.machineId,
          machineName: error.machineName,
          clientId: error.clientId,
          clientName: error.clientName,
          phase: error.phase,
          isMachine: error instanceof MachineUnavailableError,
          isClient: error instanceof ClientUnavailableError
        });
        const failures = [];
        for (const path of ["machine.lost", "client.closed", "coded.other", "plain.tool", "internal.bug"]) {
          await tools[path]({}).catch((error) => failures.push(describe(error)));
        }
        return failures;
      }`,
      (call) => {
        switch (call.path) {
          case "machine.lost":
            throw new CodeExecutionToolError("lost connection to MacBook Pro mid-call", {
              code: "machine_unavailable",
              details: { machineId: "mbp-1", name: "MacBook Pro", phase: "in-flight" }
            })
          case "client.closed":
            throw new CodeExecutionToolError("Studio side is not attached", {
              code: "client_unavailable",
              details: { clientId: "window-2", name: "Studio side", phase: "before-send" }
            })
          case "coded.other":
            throw new CodeExecutionToolError("Quota exceeded", { code: "rate_limited" })
          case "plain.tool":
            throw new CodeExecutionToolError("Issue not found")
          default:
            throw new Error("secret stack detail")
        }
      },
      {}
    )

    expect(result.error).toBeUndefined()
    expect(result.result).toEqual([
      {
        name: "MachineUnavailableError",
        message: "lost connection to MacBook Pro mid-call",
        code: "machine_unavailable",
        details: { machineId: "mbp-1", name: "MacBook Pro", phase: "in-flight" },
        machineId: "mbp-1",
        machineName: "MacBook Pro",
        phase: "in-flight",
        isMachine: true,
        isClient: false
      },
      {
        name: "ClientUnavailableError",
        message: "Studio side is not attached",
        code: "client_unavailable",
        details: { clientId: "window-2", name: "Studio side", phase: "before-send" },
        clientId: "window-2",
        clientName: "Studio side",
        phase: "before-send",
        isMachine: false,
        isClient: true
      },
      {
        name: "Error",
        message: "Quota exceeded",
        code: "rate_limited",
        isMachine: false,
        isClient: false
      },
      { name: "Error", message: "Issue not found", isMachine: false, isClient: false },
      { name: "Error", message: "Internal tool error", isMachine: false, isClient: false }
    ])
  })

  it("forwards status() text to the host as the script runs", async () => {
    const statuses: Array<string> = []
    const { result } = await execute(
      `async () => {
        status("Listing issues");
        await tools.linear.list_issues({});
        status({ step: 2 });
        status();
        return "done";
      }`,
      () => ({ issues: [] }),
      {
        onStatus: (text) => {
          statuses.push(text)
          if (text === "") throw new Error("host status sink failed")
        }
      }
    )

    expect(result).toMatchObject({ result: "done" })
    expect(statuses).toEqual(["Listing issues", '{"step":2}', ""])
  })
})
