import type { CallToolResult } from "@modelcontextprotocol/server"

import {
  actionResult,
  jsonResult,
  stringArgument,
  type BrowserRuntime,
  type PageHandle,
  type ResolvedElement
} from "./browser-cdp-engine.js"
import { withoutPointerOverlay } from "./browser-cursor.js"
import { dragBetween } from "./browser-drag.js"
import { frameOffsetInTab, tabPageOf } from "./browser-frame-offset.js"
import { routeBrowserFrame } from "./browser-frame.js"
import { locatorBackendNodeIds } from "./browser-locator-resolve.js"
import {
  callLocatorFunction,
  locatorIsVisible,
  releaseElement,
  resolveLocatorElement
} from "./browser-locators.js"
import { captureScreenshot, elementClip, screenshotFormat } from "./browser-screenshot.js"
import type { BrowserToolInvocation, BrowserToolSessionState } from "./browser-use-invoke-types.js"
import { waitBudget } from "./browser-wait-budget.js"
import { isPlainRecord, isStringArray } from "./unknown-values.js"

export const invokeElementTools = async (
  invocation: BrowserToolInvocation,
  _state: BrowserToolSessionState
): Promise<CallToolResult | undefined> => {
  const handler = elementTools[invocation.toolName]
  if (handler === undefined) return undefined

  const routed = await routeBrowserFrame(
    invocation.active,
    invocation.page,
    invocation.args.locator
  )
  return handler({
    ...invocation,
    page: routed.page,
    args: { ...invocation.args, locator: routed.locator }
  })
}

type ElementTool = (invocation: BrowserToolInvocation) => Promise<CallToolResult>

const elementFunction =
  (
    declaration: string,
    argumentsOf: (args: BrowserToolInvocation["args"]) => unknown[] = () => []
  ) =>
  async ({ active, args, page }: BrowserToolInvocation): Promise<CallToolResult> =>
    jsonResult({
      value:
        (await callLocatorFunction(
          active,
          page,
          args.locator,
          declaration,
          argumentsOf(args),
          waitBudget(args.timeoutMs)
        )) ?? null
    })

const hover: ElementTool = async ({ active, args, cursor, page, pointer }) => {
  const element = await resolveLocatorElement(
    active,
    page,
    args.locator,
    args.force !== true,
    waitBudget(args.timeoutMs)
  )
  try {
    await cursor.move(element.x, element.y)
    await active.connection.send(
      "Input.dispatchMouseEvent",
      { type: "mouseMoved", x: element.x, y: element.y },
      page.sessionId
    )
  } finally {
    await releaseElement(active, page, element)
  }
  Object.assign(pointer, { x: element.x, y: element.y })
  return actionResult(active, page, "playwright.hover", { addressing: "locator" })
}

const dragTo: ElementTool = async ({ active, args, cursor, page, pointer }) => {
  const actionable = args.force !== true
  const budget = waitBudget(args.timeoutMs)
  const start = await resolveLocatorElement(active, page, args.locator, actionable, budget)
  const end = await resolveLocatorElement(active, page, args.target, actionable, budget).finally(
    () => releaseElement(active, page, start)
  )
  await releaseElement(active, page, end)
  await dragBetween(active, page, cursor, { x: start.x, y: start.y }, { x: end.x, y: end.y })
  Object.assign(pointer, { x: end.x, y: end.y })
  return actionResult(active, page, "playwright.dragTo", { addressing: "locator" })
}

const setInputFiles: ElementTool = async ({ active, args, page }) => {
  if (!isStringArray(args.paths)) throw new Error("files must be workspace file paths")
  const ids = await locatorBackendNodeIds(active, page, args.locator)
  if (ids.length !== 1)
    throw new Error(`setInputFiles needs one file input; the locator resolved to ${ids.length}`)
  if (args.paths.length === 0)
    await callLocatorFunction(active, page, args.locator, clearFilesFunction)
  else
    await active.connection.send(
      "DOM.setFileInputFiles",
      { files: args.paths, backendNodeId: ids[0] },
      page.sessionId
    )
  return actionResult(active, page, "playwright.setInputFiles", { fileCount: args.paths.length })
}

const screenshot: ElementTool = async ({ active, args, page }) => {
  const budget = waitBudget(args.timeoutMs)
  await callLocatorFunction(active, page, args.locator, scrollIntoViewFunction, [], budget)
  const element = await resolveLocatorElement(active, page, args.locator, false, budget)
  await releaseElement(active, page, element)
  const tabPage = tabPageOf(active, page)
  const inTab = await elementInTab(active, page, element)
  const clip = await elementClip(active, tabPage, inTab)
  return withoutPointerOverlay(active, page, () =>
    captureScreenshot(active, tabPage, {
      format: screenshotFormat(args.type),
      clip,
      fullPage: false
    })
  )
}

const boundingBox: ElementTool = async ({ active, args, page }) => {
  if (!(await locatorIsVisible(active, page, args.locator))) return jsonResult({ value: null })
  const element = await resolveLocatorElement(
    active,
    page,
    args.locator,
    false,
    waitBudget(args.timeoutMs)
  )
  await releaseElement(active, page, element)
  const inTab = await elementInTab(active, page, element)
  return jsonResult({
    value: {
      x: inTab.x - inTab.width / 2,
      y: inTab.y - inTab.height / 2,
      width: inTab.width,
      height: inTab.height
    }
  })
}

const elementInTab = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  element: ResolvedElement
): Promise<ResolvedElement> => {
  const offset = await frameOffsetInTab(runtime, page.sessionId)
  return { ...element, x: element.x + offset.x, y: element.y + offset.y }
}

const clearFilesFunction =
  "function(){this.value='';this.dispatchEvent(new Event('input',{bubbles:true}));this.dispatchEvent(new Event('change',{bubbles:true}));return true;}"

const scrollIntoViewFunction =
  "function(){if(this.scrollIntoViewIfNeeded)this.scrollIntoViewIfNeeded(true);else this.scrollIntoView({block:'center',inline:'center'});return true;}"

const dispatchEventFunction = `function(type,init){
  const kinds=[[/^(click|dblclick|contextmenu|auxclick|mouse)/,MouseEvent],[/^key/,KeyboardEvent],[/^(pointer|gotpointer|lostpointer)/,PointerEvent],[/^(focus|blur)/,FocusEvent],[/^(drag|drop)/,DragEvent],[/^(input|beforeinput)$/,InputEvent],[/^wheel$/,WheelEvent]];
  const kind=kinds.find(([pattern])=>pattern.test(type));
  this.dispatchEvent(new (kind?kind[1]:Event)(type,{bubbles:true,cancelable:true,composed:true,...init}));
  return true;
}`

const inputValueFunction =
  "function(){if(!/^(INPUT|TEXTAREA|SELECT)$/.test(this.tagName))throw new Error('inputValue needs an <input>, <textarea> or <select>');return this.value;}"

const isCheckedFunction =
  "function(){if(this.matches('input[type=checkbox],input[type=radio]'))return this.checked;const state=this.getAttribute('aria-checked');if(state===null)throw new Error('isChecked needs a checkbox or radio button');return state==='true';}"

const isEditableFunction =
  "function(){const disabled=this.disabled===true||this.getAttribute('aria-disabled')==='true';const readonly=this.readOnly===true||this.getAttribute('aria-readonly')==='true';return !disabled&&!readonly;}"

const eventArguments = (args: BrowserToolInvocation["args"]): unknown[] => [
  stringArgument(args, "type"),
  isPlainRecord(args.eventInit) ? args.eventInit : {}
]

const elementTools: Readonly<Record<string, ElementTool | undefined>> = {
  "playwright.hover": hover,
  "playwright.dragTo": dragTo,
  "playwright.setInputFiles": setInputFiles,
  "playwright.screenshot": screenshot,
  "playwright.boundingBox": boundingBox,
  "playwright.focus": elementFunction("function(){this.focus();return true;}"),
  "playwright.blur": elementFunction("function(){this.blur();return true;}"),
  "playwright.scrollIntoViewIfNeeded": elementFunction(scrollIntoViewFunction),
  "playwright.dispatchEvent": elementFunction(dispatchEventFunction, eventArguments),
  "playwright.inputValue": elementFunction(inputValueFunction),
  "playwright.isChecked": elementFunction(isCheckedFunction),
  "playwright.isEditable": elementFunction(isEditableFunction),
  "playwright.innerHTML": elementFunction("function(){return this.innerHTML;}")
}
