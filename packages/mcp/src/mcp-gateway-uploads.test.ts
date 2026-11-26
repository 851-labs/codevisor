import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { basename, join } from "node:path"

import { FLEET_UPLOAD_FILES_PATH, FleetUploadFilesRequest, decode } from "@codevisor/api"
import { makeBrowserUseProvider, textToolResult } from "@codevisor/automation"
import { afterEach, describe, expect, it } from "vitest"

import {
  cleanupMcpManagerTests,
  directories,
  run,
  testManager
} from "./mcp-manager-test-support.js"
import type { GatewayOrigin } from "./mcp-manager-types.js"

afterEach(cleanupMcpManagerTests)

interface Upload {
  readonly name: string
  readonly content: string
}

const laptop = { id: "mbp", name: "MacBook Pro" }
const studio = { id: "studio", name: "Mac Studio" }

const agentMachine = async () => {
  const { db, manager, directory } = await testManager({ machine: laptop })
  const workspace = join(directory, "workspace")
  await mkdir(join(workspace, "docs"), { recursive: true })
  await writeFile(join(workspace, "docs", "report.pdf"), "%PDF signed release")
  await writeFile(join(directory, "outside.txt"), "not in the workspace")
  const project = await run(db.createProject({ folderPath: workspace }))
  const session = await run(db.createSession({ harnessId: "codex", projectId: project.id }))
  return { manager, sessionId: session.id }
}

const chromeMachine = async (agent: Awaited<ReturnType<typeof agentMachine>>) => {
  const root = await mkdtemp(join(tmpdir(), "gateway-remote-uploads-"))
  directories.push(root)
  const provider = makeBrowserUseProvider(root, "http://127.0.0.1:43210")
  const uploads: Array<Upload> = []
  const { manager } = await testManager({
    machine: studio,
    makeBrowserProvider: () => ({
      ...provider,
      invoke: async (context, name, args) => {
        if (name !== "upload_files") return provider.invoke(context, name, args)
        const paths = Array.isArray(args.paths) ? args.paths.map(String) : []
        for (const path of paths) {
          uploads.push({ name: basename(path), content: await readFile(path, "utf8") })
        }
        return textToolResult(JSON.stringify({ uploaded: paths.length }))
      }
    }),
    remoteInvoker: async (machine, path, args, origin) => {
      expect({ machine, path, origin }).toEqual({
        machine: laptop.id,
        path: FLEET_UPLOAD_FILES_PATH,
        origin: { machineId: studio.id, machineName: studio.name }
      })
      const request = decode(FleetUploadFilesRequest)(args)
      return agent.manager.readUploadFiles(request.sessionId, request.paths)
    }
  })
  return { manager, uploads }
}

describe("browser uploads from an agent on another machine", () => {
  it("attaches a file from the calling chat's workspace to Chrome on this machine", async () => {
    const agent = await agentMachine()
    const chrome = await chromeMachine(agent)
    const origin: GatewayOrigin = {
      machineId: laptop.id,
      machineName: laptop.name,
      sessionId: agent.sessionId
    }

    await chrome.manager.invokeRemoteGatewayCall(origin, "browser.upload_files", {
      paths: ["docs/report.pdf"]
    })

    expect(chrome.uploads).toEqual([{ name: "report.pdf", content: "%PDF signed release" }])
  })

  it("refuses files outside that workspace, and calls that don't come from a chat", async () => {
    const agent = await agentMachine()
    const chrome = await chromeMachine(agent)
    const fromChat = { machineId: laptop.id, machineName: laptop.name, sessionId: agent.sessionId }
    const fromNoChat = { machineId: laptop.id, machineName: laptop.name }
    const upload = (origin: GatewayOrigin, path: string) =>
      chrome.manager.invokeRemoteGatewayCall(origin, "browser.upload_files", { paths: [path] })

    await expect(upload(fromChat, "../outside.txt")).rejects.toThrow(
      "Browser Use can only upload files from the current workspace"
    )
    await expect(upload(fromNoChat, "docs/report.pdf")).rejects.toThrow(
      "this call from MacBook Pro isn't from a chat"
    )
    expect(chrome.uploads).toEqual([])
  })
})
