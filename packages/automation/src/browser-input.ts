import { delay, evaluatedValue } from "./browser-cdp.js"
import type { BrowserRuntime, PageHandle, ResolvedElement } from "./browser-cdp-engine.js"
import type { BrowserCursor } from "./browser-cursor.js"
import { releaseElement, resolveElement } from "./browser-locators.js"

export {
  browserKeyDescription,
  dispatchKeyEvent,
  heldKeyDescription,
  modifierKeyMask,
  pressKey
} from "./browser-keyboard.js"

export type MouseButton = "left" | "right" | "middle"

/**
 * Where a session's pointer is and which buttons it holds, mirroring Playwright's `Mouse`, so
 * `move → down → move → up` sequences compose into real drags and `wheel` scrolls in place.
 */
export interface PointerState {
  x: number
  y: number
  buttons: number
  /** Keyboard modifier mask currently held through key_down, mirroring Playwright's `Keyboard`. */
  modifiers: number
}

export const initialPointerState = (): PointerState => ({ x: 0, y: 0, buttons: 0, modifiers: 0 })

export const mouseButtonName = (value: unknown): MouseButton =>
  value === "right" || value === "middle" ? value : "left"

export const mouseButtonMask = (button: MouseButton): number =>
  button === "left" ? 1 : button === "right" ? 2 : 4

/** The CDP `button` to report on a move while buttons are held; Chrome wants the primary one. */
export const heldButtonName = (buttons: number): MouseButton | undefined =>
  (buttons & 1) !== 0
    ? "left"
    : (buttons & 2) !== 0
      ? "right"
      : (buttons & 4) !== 0
        ? "middle"
        : undefined

export interface MouseDispatch {
  readonly dialogOpened: boolean
  readonly completion: Promise<void>
}

/**
 * Dispatch one trusted mouse event, racing it against a modal JavaScript dialog. Chrome
 * deliberately keeps the input command pending while a dialog is open, so the event is reported
 * as delivered and the caller can let the next tool inspect and handle the dialog.
 */
export const dispatchMouseEvent = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  params: Readonly<Record<string, unknown>>
): Promise<MouseDispatch> => {
  let resolveDialog = (): void => undefined
  const dialog = new Promise<void>((resolve) => {
    resolveDialog = resolve
  })
  const stop = runtime.connection.on(
    "Page.javascriptDialogOpening",
    () => resolveDialog(),
    page.sessionId
  )
  const command = runtime.connection
    .send("Input.dispatchMouseEvent", params, page.sessionId)
    .then(() => undefined)
  try {
    const outcome = await Promise.race([
      command.then(() => "completed" as const),
      dialog.then(() => "dialog" as const)
    ])
    if (outcome === "completed") return { dialogOpened: false, completion: command }
    const completion = command.catch(() => undefined)
    return { dialogOpened: true, completion }
  } finally {
    stop()
  }
}

export const dispatchClick = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  x: number,
  y: number,
  button: string,
  count: number,
  modifiers = 0,
  cursor?: BrowserCursor
): Promise<void> => {
  const normalized = mouseButtonName(button)
  const buttonMask = mouseButtonMask(normalized)
  const dispatch = (params: Readonly<Record<string, unknown>>): Promise<MouseDispatch> =>
    dispatchMouseEvent(runtime, page, params)

  // Let the presented pointer arrive before the trusted input lands, as Computer Use does.
  await cursor?.move(x, y)
  const moved = await dispatch({ type: "mouseMoved", x, y, modifiers })
  if (moved.dialogOpened) return
  for (let clickCount = 1; clickCount <= count; clickCount++) {
    const pressed = await dispatch({
      type: "mousePressed",
      x,
      y,
      button: normalized,
      buttons: buttonMask,
      clickCount,
      modifiers
    })
    if (pressed.dialogOpened) {
      void pressed.completion.then(() =>
        runtime.connection
          .send(
            "Input.dispatchMouseEvent",
            {
              type: "mouseReleased",
              x,
              y,
              button: normalized,
              buttons: 0,
              clickCount,
              modifiers
            },
            page.sessionId
          )
          .then(() => undefined)
          .catch(() => undefined)
      )
      return
    }
    await delay(25)
    const released = await dispatch({
      type: "mouseReleased",
      x,
      y,
      button: normalized,
      buttons: 0,
      clickCount,
      modifiers
    })
    if (released.dialogOpened) return
    if (clickCount < count) await delay(80)
  }
  await cursor?.pulse(x, y)
}

export const triggerMediaDownload = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  objectId: string
): Promise<void> => {
  const result = evaluatedValue<{ error?: string }>(
    await runtime.connection.send(
      "Runtime.callFunctionOn",
      {
        objectId,
        functionDeclaration:
          "function(){const url=this.currentSrc||this.src||this.href;if(!url)return{error:'The target has no media URL'};const link=document.createElement('a');link.href=url;link.download='';link.style.display='none';document.body.append(link);link.click();link.remove();return{};}",
        returnByValue: true,
        userGesture: true
      },
      page.sessionId
    )
  )
  if (result.error !== undefined) throw new Error(result.error)
}

export const mediaElementAtPoint = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  x: number,
  y: number
): Promise<string> => {
  const evaluated = await runtime.connection.send<{ result: { objectId?: string } }>(
    "Runtime.evaluate",
    {
      expression: `document.elementFromPoint(${JSON.stringify(x)},${JSON.stringify(y)})`,
      returnByValue: false
    },
    page.sessionId
  )
  const objectId = evaluated.result.objectId
  if (objectId === undefined) throw new Error("No element exists at that viewport coordinate")
  return objectId
}

export const fillResolvedElement = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  element: ResolvedElement,
  text: string,
  slowly: boolean,
  replace: boolean
): Promise<string | undefined> => {
  const preparation = evaluatedValue<{
    actual?: string
    error?: string
    needsInput?: boolean
    type?: string
  }>(
    await runtime.connection.send(
      "Runtime.callFunctionOn",
      {
        objectId: element.objectId,
        functionDeclaration:
          "function(value,replace){const tag=this.tagName?.toLowerCase();const type=tag==='input'?String(this.type||'text').toLowerCase():tag;const setValueTypes=new Set(['color','date','time','datetime-local','month','range','week']);const typeableTypes=new Set(['text','email','number','password','search','tel','url']);if(tag==='input'){if(!typeableTypes.has(type)&&!setValueTypes.has(type))return {error:`Input type ${type} cannot be filled`,type};if(type==='number'&&Number.isNaN(Number(String(value).trim())))return {error:'Cannot type text into input[type=number]',type};if(setValueTypes.has(type)){const normalized=String(value).trim();this.focus();this.value=type==='color'?normalized.toLowerCase():normalized;if(this.value!==normalized.toLowerCase())return {error:`Malformed value for input[type=${type}]`,actual:this.value,type};this.dispatchEvent(new Event('input',{bubbles:true,composed:true}));this.dispatchEvent(new Event('change',{bubbles:true}));return {actual:this.value,type};}}else if(tag!=='textarea'&&!this.isContentEditable)return {error:'Element is not an <input>, <textarea> or [contenteditable] element',type};this.focus();if(replace){if(typeof this.select==='function')this.select();else{const selection=getSelection(),range=document.createRange();range.selectNodeContents(this);selection.removeAllRanges();selection.addRange(range);}}return {needsInput:true,type};}",
        arguments: [{ value: text }, { value: replace }],
        returnByValue: true
      },
      page.sessionId
    )
  )
  if (preparation.error !== undefined) throw new Error(preparation.error)
  if (preparation.needsInput === true) {
    if (slowly) {
      for (const character of text) {
        await runtime.connection.send("Input.insertText", { text: character }, page.sessionId)
        await delay(35)
      }
    } else await runtime.connection.send("Input.insertText", { text }, page.sessionId)
  }
  const actual = evaluatedValue<string | undefined>(
    await runtime.connection.send(
      "Runtime.callFunctionOn",
      {
        objectId: element.objectId,
        functionDeclaration:
          "function(){if(this.tagName?.toLowerCase()==='input'||this.tagName?.toLowerCase()==='textarea')return String(this.value);if(this.isContentEditable)return String(this.textContent||'');return undefined;}",
        returnByValue: true
      },
      page.sessionId
    )
  )
  if (replace && actual !== text && preparation.actual === undefined) {
    throw new Error(
      `Browser fill verification failed: expected ${JSON.stringify(text)}, received ${JSON.stringify(actual)}`
    )
  }
  return actual
}

export const fillElement = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  target: unknown,
  text: string,
  slowly: boolean,
  cursor?: BrowserCursor
): Promise<void> => {
  const element = await resolveElement(runtime, page, target)
  try {
    await cursor?.move(element.x, element.y)
    await fillResolvedElement(runtime, page, element, text, slowly, true)
  } finally {
    await releaseElement(runtime, page, element)
  }
}

const checkedState = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  element: ResolvedElement
): Promise<{ checked?: boolean; error?: string; radio?: boolean }> =>
  evaluatedValue(
    await runtime.connection.send(
      "Runtime.callFunctionOn",
      {
        objectId: element.objectId,
        functionDeclaration:
          "function(){const tag=this.tagName?.toLowerCase(),type=String(this.type||'').toLowerCase();if(tag!=='input'||(type!=='checkbox'&&type!=='radio'))return {error:'Element is not a checkbox or radio button'};return {checked:!!this.checked,radio:type==='radio'};}",
        returnByValue: true
      },
      page.sessionId
    )
  )

export const setCheckedElement = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  element: ResolvedElement,
  desired: boolean,
  cursor?: BrowserCursor
): Promise<void> => {
  const before = await checkedState(runtime, page, element)
  if (before.error !== undefined) throw new Error(before.error)
  if (before.checked === desired) return
  if (before.radio === true && !desired) {
    throw new Error("Radio buttons can only be unchecked by selecting another radio button")
  }
  await dispatchClick(runtime, page, element.x, element.y, "left", 1, 0, cursor)
  const after = await checkedState(runtime, page, element)
  if (after.checked !== desired) {
    throw new Error(`Clicking the control did not change its checked state to ${desired}`)
  }
}

export const selectOptionsElement = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  element: ResolvedElement,
  values: ReadonlyArray<unknown>
): Promise<string[]> => {
  const result = evaluatedValue<{ error?: string; selected?: string[] }>(
    await runtime.connection.send(
      "Runtime.callFunctionOn",
      {
        objectId: element.objectId,
        functionDeclaration:
          "function(values){if(this.tagName?.toLowerCase()!=='select')return {error:'Element is not a <select> element'};const options=[...this.options],selected=[];for(const requested of values){const spec=typeof requested==='string'?{valueOrLabel:requested}:requested||{};const option=options.find((candidate,index)=>(spec.valueOrLabel===undefined||(candidate.value===spec.valueOrLabel||candidate.label===spec.valueOrLabel))&&(spec.value===undefined||candidate.value===spec.value)&&(spec.label===undefined||candidate.label===spec.label)&&(spec.index===undefined||index===spec.index));if(!option)return {error:`Option not found: ${JSON.stringify(requested)}`};if(option.disabled)return {error:`Option is disabled: ${option.label}`};if(!selected.includes(option))selected.push(option);}if(!this.multiple&&selected.length>1)return {error:'A single-select control cannot select multiple options'};for(const option of options)option.selected=selected.includes(option);this.dispatchEvent(new Event('input',{bubbles:true,composed:true}));this.dispatchEvent(new Event('change',{bubbles:true}));return {selected:[...this.selectedOptions].map(option=>option.value)};}",
        arguments: [{ value: values }],
        returnByValue: true
      },
      page.sessionId
    )
  )
  if (result.error !== undefined) throw new Error(result.error)
  return result.selected ?? []
}

export const mouseModifierMask = (value: unknown): number => {
  if (value === undefined) return 0
  if (!Array.isArray(value) || !value.every((entry) => typeof entry === "string")) {
    throw new Error("modifiers must be an array of keyboard modifier names")
  }
  let mask = 0
  for (const entry of value) {
    switch (entry.toLocaleLowerCase()) {
      case "alt":
      case "option":
        mask |= 1
        break
      case "control":
      case "ctrl":
        mask |= 2
        break
      case "controlormeta":
        mask |= process.platform === "darwin" ? 4 : 2
        break
      case "meta":
      case "cmd":
      case "command":
        mask |= 4
        break
      case "shift":
        mask |= 8
        break
      default:
        throw new Error(`Unsupported mouse modifier: ${entry}`)
    }
  }
  return mask
}
