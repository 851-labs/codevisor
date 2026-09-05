import { exportBrowserContent } from "./browser-content.js"
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"
import { randomUUID } from "node:crypto"
import { mkdirSync, writeFileSync } from "node:fs"
import { basename, join } from "node:path"
import { delay } from "./browser-cdp.js"
import {
  attachTarget,
  evaluate,
  evaluateReadOnly,
  grantClipboardPermissions,
  jsonResult,
  numberArgument,
  stringArgument
} from "./browser-cdp-engine.js"
import type { BrowserToolInvocation, BrowserToolSessionState } from "./browser-use-invoke-types.js"

/// Clipboard, console logs, dialogs, viewport, raw CDP access, and page asset bundling.
/// Returns undefined for tool names this family does not own.
export const invokePageTools = async (
  invocation: BrowserToolInvocation,
  state: BrowserToolSessionState
): Promise<CallToolResult | undefined> => {
  const { active, args, backend, page, toolName } = invocation
  const { assetInventories, assetsDir } = state
  switch (toolName) {
    case "content.export":
      return exportBrowserContent(active, page, state.assetsDir, String(args.format ?? "markdown"))
    case "clipboard.readText": {
      if (backend === "extension") {
        const value = await active.connection.send<{ text?: string }>(
          "Codevisor.clipboard.readText"
        )
        return jsonResult({ text: String(value.text ?? "") })
      }
      await grantClipboardPermissions(active, page)
      const value = await evaluateReadOnly<string>(
        active,
        page,
        "async () => await navigator.clipboard.readText()",
        undefined
      )
      return jsonResult({ text: value })
    }
    case "clipboard.writeText": {
      const text = stringArgument(args, "text")
      if (backend === "extension") {
        await active.connection.send("Codevisor.clipboard.writeText", { text })
        return jsonResult({ written: true })
      }
      await grantClipboardPermissions(active, page)
      await active.connection.send(
        "Runtime.evaluate",
        {
          expression: `navigator.clipboard.writeText(${JSON.stringify(text)})`,
          awaitPromise: true,
          userGesture: true,
          returnByValue: true
        },
        page.sessionId
      )
      return jsonResult({ written: true })
    }
    case "clipboard.read": {
      if (backend === "extension") {
        const value = await active.connection.send<{ items?: unknown[] }>(
          "Codevisor.clipboard.read"
        )
        return jsonResult({ items: value.items ?? [] })
      }
      await grantClipboardPermissions(active, page)
      const rawItems = await evaluateReadOnly<
        Array<{ readonly types: string[]; readonly data: Readonly<Record<string, string>> }>
      >(
        active,
        page,
        "async () => Promise.all((await navigator.clipboard.read()).map(async item => ({types:[...item.types],data:Object.fromEntries(await Promise.all(item.types.map(async type=>{const bytes=new Uint8Array(await (await item.getType(type)).arrayBuffer());let binary='';for(let index=0;index<bytes.length;index+=0x8000)binary+=String.fromCharCode(...bytes.subarray(index,index+0x8000));return [type,btoa(binary)];})))})))",
        undefined
      )
      return jsonResult({
        items: rawItems.map((item) => ({
          entries: item.types.map((mimeType) => {
            const base64 = item.data[mimeType] ?? ""
            return mimeType.startsWith("text/")
              ? { mimeType, text: Buffer.from(base64, "base64").toString("utf8") }
              : { mimeType, base64 }
          })
        }))
      })
    }
    case "clipboard.write": {
      if (!Array.isArray(args.items)) throw new Error("items must be an array")
      if (backend === "extension") {
        await active.connection.send("Codevisor.clipboard.write", { items: args.items })
        return jsonResult({ written: true })
      }
      await grantClipboardPermissions(active, page)
      await active.connection.send(
        "Runtime.evaluate",
        {
          expression: `(async(items)=>navigator.clipboard.write(items.map(item=>new ClipboardItem(Object.fromEntries((item.entries??[]).map(entry=>{if(typeof entry.text==='string')return[entry.mimeType,new Blob([entry.text],{type:entry.mimeType})];const binary=atob(entry.base64??''),bytes=Uint8Array.from(binary,char=>char.charCodeAt(0));return[entry.mimeType,new Blob([bytes],{type:entry.mimeType})]})),{presentationStyle:item.presentationStyle}))))(${JSON.stringify(args.items)})`,
          awaitPromise: true,
          userGesture: true,
          returnByValue: true
        },
        page.sessionId
      )
      return jsonResult({ written: true })
    }
    case "dev.logs": {
      const levels =
        Array.isArray(args.levels) && args.levels.every((level) => typeof level === "string")
          ? new Set(args.levels.map((level) => (level === "warning" ? "warn" : level)))
          : undefined
      const filter = typeof args.filter === "string" ? args.filter : undefined
      const normalized = (active.logs.get(page.sessionId) ?? []).map((entry) => {
        if (entry.method === "Runtime.consoleAPICalled") {
          const args = Array.isArray(entry.args)
            ? (entry.args as Array<Readonly<Record<string, unknown>>>)
            : []
          const message = args
            .map((value) => String(value.value ?? value.description ?? value.type ?? ""))
            .join(" ")
          return {
            level: entry.type === "warning" ? "warn" : String(entry.type ?? "log"),
            message,
            timestamp: new Date(Number(entry.timestamp ?? Date.now())).toISOString()
          }
        }
        if (entry.method === "Log.entryAdded") {
          const value =
            entry.entry !== null && typeof entry.entry === "object"
              ? (entry.entry as Readonly<Record<string, unknown>>)
              : {}
          return {
            level: value.level === "warning" ? "warn" : String(value.level ?? "log"),
            message: String(value.text ?? ""),
            timestamp: new Date(Number(value.timestamp ?? Date.now())).toISOString(),
            ...(typeof value.url === "string" ? { url: value.url } : {})
          }
        }
        const detail =
          entry.exceptionDetails !== null && typeof entry.exceptionDetails === "object"
            ? (entry.exceptionDetails as Readonly<Record<string, unknown>>)
            : {}
        const exception =
          detail.exception !== null && typeof detail.exception === "object"
            ? (detail.exception as Readonly<Record<string, unknown>>)
            : {}
        return {
          level: "error",
          message: String(exception.description ?? detail.text ?? "Uncaught page error"),
          timestamp: new Date(Number(entry.timestamp ?? Date.now())).toISOString(),
          ...(typeof detail.url === "string" ? { url: detail.url } : {})
        }
      })
      const entries = normalized
        .filter(
          (entry) =>
            (levels === undefined || levels.has(entry.level)) &&
            (filter === undefined || entry.message.includes(filter))
        )
        .slice(-Math.max(1, Math.min(1_000, Number(args.limit ?? 100))))
      return jsonResult({ entries })
    }
    case "getJsDialog":
      return jsonResult({ dialog: active.dialogs.get(page.sessionId) ?? null })
    case "viewport.set": {
      const width = Math.round(numberArgument(args, "width"))
      const height = Math.round(numberArgument(args, "height"))
      await active.connection.send(
        "Emulation.setDeviceMetricsOverride",
        { width, height, deviceScaleFactor: 1, mobile: false },
        page.sessionId
      )
      return jsonResult({ width, height })
    }
    case "viewport.reset":
      await active.connection.send("Emulation.clearDeviceMetricsOverride", {}, page.sessionId)
      return jsonResult({ reset: true })
    case "cdp.send": {
      const method = stringArgument(args, "method")
      const target =
        args.target !== null && typeof args.target === "object"
          ? (args.target as Readonly<Record<string, unknown>>)
          : undefined
      let sessionId = page.sessionId
      if (typeof target?.sessionId === "string") sessionId = target.sessionId
      if (typeof target?.targetId === "string") {
        sessionId = await attachTarget(active, target.targetId)
      }
      const params =
        args.params !== null && typeof args.params === "object" && !Array.isArray(args.params)
          ? (args.params as Readonly<Record<string, unknown>>)
          : {}
      const timeoutMs = Math.max(0, Math.min(30_000, Number(args.timeoutMs ?? 30_000)))
      return jsonResult({
        result: await active.connection.send(method, params, sessionId, timeoutMs)
      })
    }
    case "cdp.readEvents": {
      const afterSequence =
        typeof args.afterSequence === "number"
          ? Math.max(0, args.afterSequence)
          : active.eventSequence
      const limit = Math.max(1, Math.min(1_000, Number(args.limit ?? 100)))
      const methods =
        Array.isArray(args.methods) && args.methods.every((method) => typeof method === "string")
          ? new Set(args.methods)
          : undefined
      const target =
        args.target !== null && typeof args.target === "object"
          ? (args.target as Readonly<Record<string, unknown>>)
          : undefined
      const targetSession =
        typeof target?.sessionId === "string"
          ? target.sessionId
          : typeof target?.targetId === "string"
            ? active.sessions.get(target.targetId)
            : page.sessionId
      const matches = () =>
        active.eventLog.filter((event) => {
          const eventSessionId =
            event.sessionId ??
            (event.method === "Target.detachedFromTarget" &&
            typeof event.params.sessionId === "string"
              ? event.params.sessionId
              : undefined)
          return (
            event.sequence > afterSequence &&
            (methods === undefined || methods.has(event.method)) &&
            (targetSession === undefined || eventSessionId === targetSession)
          )
        })
      const timeoutMs = Math.max(0, Math.min(30_000, Number(args.timeoutMs ?? 0)))
      const deadline = Date.now() + timeoutMs
      while (matches().length === 0 && Date.now() < deadline) await delay(50)
      const all = matches()
      const events = all.slice(0, limit).map((event) => {
        const eventSessionId =
          event.sessionId ??
          (event.method === "Target.detachedFromTarget" &&
          typeof event.params.sessionId === "string"
            ? event.params.sessionId
            : undefined)
        return {
          method: event.method,
          params: event.params,
          sequence: event.sequence,
          source: {
            ...(eventSessionId === undefined ? {} : { sessionId: eventSessionId }),
            targetId:
              [...active.sessions.entries()].find(
                ([, sessionId]) => sessionId === eventSessionId
              )?.[0] ??
              (eventSessionId === undefined
                ? undefined
                : active.staleSessions.get(eventSessionId)) ??
              page.target.targetId
          }
        }
      })
      return jsonResult({
        cursor: events.at(-1)?.sequence ?? active.eventSequence,
        events,
        hasMore: all.length > events.length,
        truncated: active.eventLog.length > 0 && afterSequence < active.eventLog[0]!.sequence - 1
      })
    }
    case "pageAssets.list": {
      const inventory = await evaluate<{
        pageUrl: string
        assets: Array<{ url: string; kind: string }>
        inlineSvgs: Array<{ markup: string }>
      }>(
        active,
        page,
        `(()=>{const urls=new Map();const classify=kind=>kind==='img'?'image':kind==='css'||kind==='link'?'stylesheet':kind==='video'||kind==='media'||kind==='audio'||kind==='source'?'video':kind==='script'?'script':kind==='font'?'font':'other';const add=(url,kind)=>{try{const absolute=new URL(url,location.href).href;if(!urls.has(absolute))urls.set(absolute,{url:absolute,kind:classify(kind)});}catch{}};for(const entry of performance.getEntriesByType('resource'))add(entry.name,entry.initiatorType||'other');for(const element of document.querySelectorAll('img[src],video[src],audio[src],source[src],script[src],link[href]'))add(element.src||element.href,element.tagName.toLowerCase());return{pageUrl:location.href,assets:[...urls.values()],inlineSvgs:[...document.querySelectorAll('svg')].map(svg=>({markup:svg.outerHTML}))};})()`
      )
      const id = randomUUID()
      const normalized = {
        pageUrl: inventory.pageUrl,
        assets: inventory.assets.map((asset, index) => ({
          id: `a${index + 1}`,
          ...asset,
          name: (() => {
            try {
              return basename(new URL(asset.url).pathname) || `asset-${index + 1}`
            } catch {
              return `asset-${index + 1}`
            }
          })(),
          sources: [{ kind: "resource" }]
        })),
        inlineSvgs: inventory.inlineSvgs.map((asset, index) => ({
          id: `s${index + 1}`,
          ...asset,
          name: `inline-${index + 1}.svg`
        }))
      }
      assetInventories.set(id, normalized)
      const byKind = Object.fromEntries(
        [...new Set(normalized.assets.map((asset) => asset.kind))].map((kind) => [
          kind,
          normalized.assets.filter((asset) => asset.kind === kind).length
        ])
      )
      return jsonResult({
        id,
        ...normalized,
        summary: {
          byKind,
          inlineSvgCount: normalized.inlineSvgs.length,
          totalCount: normalized.assets.length + normalized.inlineSvgs.length
        }
      })
    }
    case "pageAssets.bundle": {
      const inventoryId = stringArgument(args, "inventoryId")
      const inventory = assetInventories.get(inventoryId)
      if (inventory === undefined) throw new Error("Unknown or expired page asset inventory")
      const selectedIds =
        Array.isArray(args.assetIds) &&
        args.assetIds.every((assetId) => typeof assetId === "string")
          ? new Set(args.assetIds)
          : undefined
      const kinds =
        Array.isArray(args.kinds) && args.kinds.every((kind) => typeof kind === "string")
          ? new Set(args.kinds)
          : undefined
      const bundleDir = join(assetsDir, inventoryId)
      mkdirSync(bundleDir, { recursive: true, mode: 0o700 })
      const saved: Array<{
        contentType: string | null
        id: string
        kind: string
        name: string
        path: string
        url: string
      }> = []
      const failures: Array<{
        contentType: string | null
        id: string
        name: string
        reason: string
        url: string
      }> = []
      const requested = inventory.assets.filter(
        (asset) =>
          (selectedIds === undefined || selectedIds.has(asset.id)) &&
          (kinds === undefined || kinds.has(asset.kind))
      )
      const startedAt = Date.now()
      for (const asset of inventory.assets) {
        if (selectedIds !== undefined && !selectedIds.has(asset.id)) continue
        if (kinds !== undefined && !kinds.has(asset.kind)) continue
        const fetched = await evaluate<{ base64?: string; mimeType?: string; error?: string }>(
          active,
          page,
          `(async()=>{try{const response=await fetch(${JSON.stringify(asset.url)});if(!response.ok)return{error:String(response.status)};const bytes=new Uint8Array(await response.arrayBuffer());let binary='';for(let index=0;index<bytes.length;index+=0x8000)binary+=String.fromCharCode(...bytes.subarray(index,index+0x8000));return{base64:btoa(binary),mimeType:response.headers.get('content-type')||undefined};}catch(error){return{error:String(error)}}})()`
        )
        if (fetched.base64 === undefined) {
          failures.push({
            contentType: fetched.mimeType ?? null,
            id: asset.id,
            name: asset.name,
            reason: fetched.error ?? "Download failed",
            url: asset.url
          })
          continue
        }
        const path = join(
          bundleDir,
          `${asset.id}-${asset.name.replaceAll(/[^a-zA-Z0-9._-]/g, "_")}`
        )
        writeFileSync(path, Buffer.from(fetched.base64, "base64"), { mode: 0o600 })
        saved.push({
          contentType: fetched.mimeType ?? null,
          id: asset.id,
          kind: asset.kind,
          name: asset.name,
          path,
          url: asset.url
        })
      }
      const manifestPath = join(bundleDir, "manifest.json")
      writeFileSync(
        manifestPath,
        JSON.stringify(
          { inventoryId, pageUrl: inventory.pageUrl, assets: saved, failures },
          null,
          2
        ),
        { mode: 0o600 }
      )
      return jsonResult({
        assets: saved,
        directoryPath: bundleDir,
        failures,
        manifestPath,
        summary: {
          downloadedCount: saved.length,
          elapsedMs: Date.now() - startedAt,
          failedCount: failures.length,
          requestedCount: requested.length
        }
      })
    }
    default:
      return undefined
  }
}
