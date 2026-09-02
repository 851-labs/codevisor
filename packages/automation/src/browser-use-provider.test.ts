import { createServer } from "node:http"
import { rmSync, existsSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterEach, describe, expect, it } from "vitest"
import { makeBrowserUseProvider } from "./browser-use-provider.js"

const directories: string[] = []

afterEach(() => {
  for (const directory of directories.splice(0)) rmSync(directory, { force: true, recursive: true })
})

describe("Browser Use direct CDP engine", () => {
  it(
    "navigates, snapshots, and clicks through the direct CDP engine",
    { timeout: 90_000 },
    async () => {
      const directory = mkdtempSync(join(tmpdir(), "codevisor-browser-cdp-"))
      directories.push(directory)
      const previousHeadless = process.env.CODEVISOR_BROWSER_HEADLESS
      process.env.CODEVISOR_BROWSER_HEADLESS = "1"
      const provider = makeBrowserUseProvider(directory)
      const server = createServer((request, response) => {
        if (request.url === "/fixture.txt") {
          response.writeHead(200, {
            "content-disposition": 'attachment; filename="fixture.txt"',
            "content-type": "text/plain"
          })
          response.end("download fixture")
          return
        }
        response.writeHead(200, { "content-type": "text/html" })
        response.end(`<!doctype html><title>CDP fixture</title>
        <button onclick="document.querySelector('#count').textContent = '1'">Increment</button>
        <button id="dialog-button" onclick="confirm('confirm click fixture')">Dialog</button>
        <a id="download-link" href="/fixture.txt" download>Download</a>
        <p id="count">0</p>
        <label>Name <input id="person-name" placeholder="Full name"></label>
        <label>Date <input id="date" type="date"></label>
        <label>Agree <input id="agree" type="checkbox"></label>
        <label>Choice <select id="choice"><option value="one">One</option><option value="two">Two</option></select></label>
        <label>Upload <input id="upload" type="file" multiple></label>
        <ul>
          <li class="row"><span>Ada</span> <button>Edit</button></li>
          <li class="row" style="display:none"><span>Hidden Ada</span> <button>Edit</button></li>
          <li class="row">Grace <button>View</button></li>
        </ul>
        <iframe srcdoc="<p class='frame-copy'>Frame One</p><p class='frame-copy'>Frame Two</p>"></iframe>
        <pre id="output"></pre>
        <script>
        const update = () => document.querySelector('#output').textContent = JSON.stringify({
          name: document.querySelector('#person-name').value,
          date: document.querySelector('#date').value,
          agree: document.querySelector('#agree').checked,
          choice: document.querySelector('#choice').value
        });
        document.querySelectorAll('input,select').forEach(element => {
          element.addEventListener('input', update);
          element.addEventListener('change', update);
        });
        update();
        </script>`)
      })
      await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve))
      try {
        if (provider.status().backend === "missing") return
        const address = server.address()
        if (address === null || typeof address === "string") throw new Error("Missing fixture port")
        const context = { sessionId: "browser-test", projectId: "browser-test" }
        await provider.invoke(context, "use_backend", { backend: "managed" })
        const navigated = await provider.invoke(context, "navigate", {
          url: `http://127.0.0.1:${address.port}/`
        })
        expect(navigated.isError, JSON.stringify(navigated.content)).not.toBe(true)

        const first = await provider.invoke(context, "snapshot", {})
        const firstText = first.content.find((block) => block.type === "text")
        expect(firstText?.type).toBe("text")
        const ref =
          firstText?.type === "text"
            ? firstText.text.match(/button "Increment" \[ref=(e\d+)\]/)?.[1]
            : undefined
        expect(ref).toMatch(/^e\d+$/)

        const clicked = await provider.invoke(context, "click", {
          target: ref,
          element: "Increment"
        })
        expect(clicked.isError).not.toBe(true)
        expect(clicked.content[0]).toMatchObject({ type: "text" })
        if (clicked.content[0]?.type === "text")
          expect(clicked.content[0].text).toContain('"path": "cdp"')

        const second = await provider.invoke(context, "snapshot", {})
        const secondText = second.content.find((block) => block.type === "text")
        if (secondText?.type !== "text") throw new Error("Missing snapshot text")
        expect(secondText.text).toMatch(/paragraph[\s\S]*StaticText "1"/)

        for (const [tool, args] of [
          [
            "playwright.fill",
            { locator: { placeholder: "Full name", exact: true }, value: "Ada Lovelace" }
          ],
          ["playwright.fill", { locator: { css: "#date" }, value: "2026-07-22" }],
          ["playwright.setChecked", { locator: { label: "Agree", exact: true }, checked: true }],
          [
            "playwright.selectOption",
            { locator: { label: "Choice", exact: true }, values: [{ label: "Two" }] }
          ]
        ] as const) {
          const result = await provider.invoke(context, tool, args)
          expect(result.isError, `${tool}: ${JSON.stringify(result.content)}`).not.toBe(true)
        }
        const output = await provider.invoke(context, "playwright.innerText", {
          locator: { css: "#output" }
        })
        if (output.content[0]?.type !== "text") throw new Error("Missing locator output")
        expect(JSON.parse(output.content[0].text)).toEqual({
          value: '{"name":"Ada Lovelace","date":"2026-07-22","agree":true,"choice":"two"}'
        })

        const composed = await provider.invoke(context, "playwright.count", {
          locator: {
            css: ".row",
            filters: {
              hasText: "Ada",
              visible: true,
              has: { role: "button", name: "Edit", exact: true }
            }
          }
        })
        if (composed.content[0]?.type !== "text") throw new Error("Missing locator count")
        expect(JSON.parse(composed.content[0].text)).toEqual({ count: 1 })

        const nested = await provider.invoke(context, "playwright.innerText", {
          locator: {
            text: "Ada",
            scope: {
              css: ".row",
              filters: { visible: true },
              index: 0
            }
          }
        })
        if (nested.content[0]?.type !== "text") throw new Error("Missing nested locator result")
        expect(JSON.parse(nested.content[0].text)).toEqual({ value: "Ada" })

        const frameContents = await provider.invoke(context, "playwright.allTextContents", {
          locator: { css: ".frame-copy", frame: ["iframe"] }
        })
        if (frameContents.content[0]?.type !== "text") throw new Error("Missing frame result")
        expect(JSON.parse(frameContents.content[0].text)).toEqual({
          values: ["Frame One", "Frame Two"]
        })

        const evaluated = await provider.invoke(context, "playwright.evaluate", {
          locator: { css: "#output" },
          function: "(element, suffix) => element.textContent + suffix",
          arg: "!"
        })
        if (evaluated.content[0]?.type !== "text") throw new Error("Missing evaluation result")
        expect(JSON.parse(evaluated.content[0].text)).toEqual({
          value: '{"name":"Ada Lovelace","date":"2026-07-22","agree":true,"choice":"two"}!'
        })
        const mutation = await provider.invoke(context, "playwright.evaluate", {
          function: "() => { document.body.textContent = 'mutated' }"
        })
        expect(mutation.isError).toBe(true)
        expect(mutation.content[0]).toMatchObject({
          type: "text",
          text: expect.stringContaining("read-only")
        })

        const viewport = await provider.invoke(context, "viewport.set", {
          width: 900,
          height: 700
        })
        expect(viewport.isError).not.toBe(true)
        const metrics = await provider.invoke(context, "cdp.send", {
          method: "Runtime.evaluate",
          params: { expression: "innerWidth", returnByValue: true }
        })
        if (metrics.content[0]?.type !== "text") throw new Error("Missing CDP result")
        expect(JSON.parse(metrics.content[0].text)).toMatchObject({
          result: { result: { value: 900 } }
        })
        await provider.invoke(context, "viewport.reset", {})

        const assets = await provider.invoke(context, "pageAssets.list", {})
        expect(assets.isError).not.toBe(true)

        const uploadPath = join(directory, "fixture.txt")
        writeFileSync(uploadPath, "browser upload fixture")
        const chooserPromise = provider.invoke(context, "playwright.waitForEvent", {
          event: "filechooser",
          timeoutMs: 5_000
        })
        await new Promise((resolve) => setTimeout(resolve, 100))
        const fileClick = await provider.invoke(context, "playwright.click", {
          locator: { css: "#upload" }
        })
        expect(fileClick.isError).not.toBe(true)
        const chooser = await chooserPromise
        if (chooser.content[0]?.type !== "text") throw new Error("Missing file chooser")
        const chooserValue = JSON.parse(chooser.content[0].text) as {
          chooserId: string
          multiple: boolean
        }
        expect(chooserValue.multiple).toBe(true)
        const setFiles = await provider.invoke(context, "playwright.fileChooserSetFiles", {
          chooserId: chooserValue.chooserId,
          paths: [uploadPath]
        })
        expect(setFiles.isError).not.toBe(true)
        const fileName = await provider.invoke(context, "playwright.evaluate", {
          locator: { css: "#upload" },
          function: "(element) => element.files[0].name"
        })
        if (fileName.content[0]?.type !== "text") throw new Error("Missing file name")
        expect(JSON.parse(fileName.content[0].text)).toEqual({ value: "fixture.txt" })

        const regexCount = await provider.invoke(context, "playwright.count", {
          locator: { role: "button", name: { regex: "^Ed.t$" } }
        })
        if (regexCount.content[0]?.type !== "text") throw new Error("Missing regex count")
        expect(JSON.parse(regexCount.content[0].text)).toEqual({ count: 1 })

        await provider.invoke(context, "cdp.send", {
          method: "Runtime.evaluate",
          params: { expression: "console.warn('codevisor-log-fixture')" }
        })
        await new Promise((resolve) => setTimeout(resolve, 25))
        const logs = await provider.invoke(context, "dev.logs", {
          filter: "codevisor-log-fixture",
          levels: ["warn"]
        })
        if (logs.content[0]?.type !== "text") throw new Error("Missing logs")
        expect(JSON.parse(logs.content[0].text)).toMatchObject({
          entries: [expect.objectContaining({ level: "warn", message: "codevisor-log-fixture" })]
        })

        const wroteClipboard = await provider.invoke(context, "clipboard.writeText", {
          text: "clipboard fixture"
        })
        expect(wroteClipboard.isError).not.toBe(true)
        const clipboard = await provider.invoke(context, "clipboard.readText", {})
        if (clipboard.content[0]?.type !== "text") throw new Error("Missing clipboard")
        expect(JSON.parse(clipboard.content[0].text)).toEqual({ text: "clipboard fixture" })

        const dialogClick = await provider.invoke(context, "playwright.click", {
          locator: { css: "#dialog-button" }
        })
        const dialog = await provider.invoke(context, "getJsDialog", {})
        expect(dialogClick, JSON.stringify({ dialogClick, dialog })).not.toMatchObject({
          isError: true
        })
        if (dialog.content[0]?.type !== "text") throw new Error("Missing dialog")
        expect(JSON.parse(dialog.content[0].text)).toMatchObject({
          dialog: { type: "confirm", message: "confirm click fixture" }
        })
        const accepted = await provider.invoke(context, "dialog", { accept: true })
        expect(accepted.isError).not.toBe(true)

        const downloadPromise = provider.invoke(context, "playwright.waitForEvent", {
          event: "download",
          timeoutMs: 5_000
        })
        await new Promise((resolve) => setTimeout(resolve, 100))
        const downloadClick = await provider.invoke(context, "playwright.click", {
          locator: { css: "#download-link" }
        })
        expect(downloadClick.isError).not.toBe(true)
        const download = await downloadPromise
        if (download.content[0]?.type !== "text") throw new Error("Missing download")
        const downloadValue = JSON.parse(download.content[0].text) as { downloadId: string }
        const downloadPath = await provider.invoke(context, "playwright.downloadPath", {
          downloadId: downloadValue.downloadId,
          timeoutMs: 5_000
        })
        if (downloadPath.content[0]?.type !== "text") throw new Error("Missing download path")
        const downloadPathValue = JSON.parse(downloadPath.content[0].text) as { path: string }
        expect(existsSync(downloadPathValue.path)).toBe(true)
      } finally {
        await provider.close()
        await new Promise<void>((resolve) => server.close(() => resolve()))
        if (previousHeadless === undefined) delete process.env.CODEVISOR_BROWSER_HEADLESS
        else process.env.CODEVISOR_BROWSER_HEADLESS = previousHeadless
      }
    }
  )
})
