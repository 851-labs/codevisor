import { describe, expect } from "vitest"

import { chromeBrowserSuite } from "./browser-chrome-test-support.js"

const dialogPage = `<title>Dialogs</title><p id="out">none</p>
  <button onclick="document.querySelector('#out').textContent = 'answer:' + prompt('Your name?', 'Ada')">Ask</button>
  <button onclick="alert('Saved'); document.querySelector('#out').textContent = 'alerted'">Tell</button>`

const draftPage = `<title>Draft</title>
  <button onclick="onbeforeunload = (event) => { event.preventDefault(); return (event.returnValue = 'unsaved') }">Start draft</button>`

const it = chromeBrowserSuite("dialogs", ({ crossOrigin }) => ({
  "/dialogs": dialogPage,
  "/draft": draftPage,
  "/framed": `<title>Framed</title><iframe id="cross" src="${crossOrigin}/dialogs"></iframe>`
}))

describe("JavaScript dialogs", () => {
  it("reads a dialog's text and a prompt's default answer before answering", async ({
    browser
  }) => {
    await browser.open("/dialogs")
    const seen = await browser.cell(`
      const page = tab.playwright
      await page.getByRole('button', {name:'Ask'}).click()
      const prompt = await tab.getJsDialog()
      await prompt.accept(prompt.defaultValue + ' Lovelace')
      await page.getByRole('button', {name:'Tell'}).click()
      const alert = await tab.getJsDialog()
      await alert.accept()
      browser.write({
        prompt: [prompt.type, prompt.message, prompt.defaultValue],
        alert: [alert.type, alert.message, alert.defaultValue],
        out: await page.locator('#out').textContent()
      })`)
    expect(seen).toEqual({
      prompt: ["prompt", "Your name?", "Ada"],
      alert: ["alert", "Saved", ""],
      out: "alerted"
    })
  })

  it("returns from a click that opens an alert inside a cross-origin frame", async ({
    browser
  }) => {
    await browser.open("/framed")
    const seen = await browser.cell(`
      const frame = tab.playwright.frameLocator('#cross')
      await frame.getByRole('button', {name:'Tell'}).click({timeoutMs: 5000})
      const alert = await tab.getJsDialog()
      await alert.accept()
      browser.write([alert.type, alert.message, await frame.locator('#out').textContent(), await tab.getJsDialog() ?? null])`)
    expect(seen).toEqual(["alert", "Saved", "alerted", null])
  })

  it("names the open dialog instead of timing out, and still reports the tab", async ({
    browser
  }) => {
    await browser.open("/dialogs")
    const blocked = await browser.cell(`
      await tab.playwright.getByRole('button', {name:'Tell'}).click()
      const refused = await tab.getAXState().catch(error => error.message)
      const title = await tab.title()
      await (await tab.getJsDialog()).accept()
      browser.write({ refused, title, after: (await tab.getAXState()).includes('button "Tell"') })`)
    expect(blocked).toEqual({
      refused:
        'A JavaScript alert is open on this tab saying "Saved", so the page can\'t respond until it is answered. Read it with tab.getJsDialog(), then call accept() or dismiss() on it.',
      title: "Dialogs",
      after: true
    })
  })

  it("lets a later turn answer a dialog that was left open", async ({ browser }) => {
    await browser.open("/dialogs")
    await browser.cell("await tab.playwright.getByRole('button', {name:'Ask'}).click()")
    await browser.endTurn()
    const answered = await browser.cell(`
      const kept = (await browser.tabs.list({scope:'session'}))[0]
      const prompt = await kept.getJsDialog()
      await prompt.accept('later')
      browser.write([prompt.message, await kept.playwright.locator('#out').textContent()])`)
    expect(answered).toEqual(["Your name?", "answer:later"])
  })

  it("returns from goto when the page asks before leaving, then stays or leaves as answered", async ({
    browser
  }) => {
    await browser.open("/draft")
    const { origin } = browser.origins
    const visited = await browser.cell(`
      await tab.playwright.getByRole('button', {name:'Start draft'}).click()
      const leave = async (answer) => {
        await tab.goto(${JSON.stringify(origin + "/dialogs")})
        const dialog = await tab.getJsDialog()
        await answer(dialog)
        return [dialog.type, await tab.title()]
      }
      browser.write([await leave(dialog => dialog.dismiss()), await leave(dialog => dialog.accept())])`)
    expect(visited).toEqual([
      ["beforeunload", "Draft"],
      ["beforeunload", "Dialogs"]
    ])
  })
})
