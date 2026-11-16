import { describe, expect } from "vitest"

import { chromeBrowserSuite } from "./browser-chrome-test-support.js"

const editorPage = `<title>Editor</title><textarea id="from">copy me</textarea><textarea id="to"></textarea>`

const it = chromeBrowserSuite("shortcuts", () => ({ "/editor": editorPage }))

describe("Editing shortcuts", () => {
  it("selects all with the platform shortcut, so typing replaces the text", async ({ browser }) => {
    await browser.open("/editor")
    expect(
      await browser.cell(`
        const field = tab.playwright.locator('#from')
        await field.press('ControlOrMeta+a')
        await field.type('replaced')
        await field.evaluate(e => e.value)`)
    ).toBe("replaced")
  })

  it.runIf(process.platform === "darwin")(
    "copies, pastes and undoes with Command shortcuts on macOS",
    async ({ browser }) => {
      await browser.open("/editor")
      expect(
        await browser.cell(`
          const from = tab.playwright.locator('#from')
          const to = tab.playwright.locator('#to')
          await tab.clipboard.writeText('')
          await from.press('Meta+a')
          await from.press('Meta+c')
          await to.press('Meta+v')
          const pasted = await to.evaluate(e => e.value)
          await to.type(' and more')
          await to.press('Meta+ArrowLeft')
          await to.type('> ')
          browser.write([pasted, await to.evaluate(e => e.value)])`)
      ).toEqual(["copy me", "> copy me and more"])
    }
  )
})
