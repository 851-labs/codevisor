/*
 * Codevisor's QuickJS bridge is adapted from @executor-js/runtime-quickjs and
 * @executor-js/codemode-core, originally published under the MIT License:
 *
 * Copyright (c) 2026 Rhys Sullivan
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

import { parse } from "@babel/parser"
import {
  getQuickJS,
  type QuickJSContext,
  type QuickJSDeferredPromise,
  type QuickJSHandle,
  type QuickJSRuntime
} from "quickjs-emscripten"
import { transform } from "sucrase"

export interface CodeExecutionResult {
  readonly result: unknown
  readonly output?: ReadonlyArray<unknown>
  readonly error?: string
  readonly logs?: ReadonlyArray<string>
}

export interface CodeToolCall {
  readonly path: string
  readonly args: unknown
}

export interface CodeToolInvoker {
  readonly invoke: (call: CodeToolCall) => Promise<unknown>
}

export interface CodeExecutorOptions {
  /** Maximum time spent actively executing code inside QuickJS. Host tool waits are excluded. */
  readonly activeTimeoutMs?: number
  readonly memoryLimitBytes?: number
  readonly maxStackSizeBytes?: number
}

export interface ExecuteCodeOptions {
  readonly signal?: AbortSignal
}

export interface CodeExecutor {
  readonly execute: (
    code: string,
    toolInvoker: CodeToolInvoker,
    options?: ExecuteCodeOptions
  ) => Promise<CodeExecutionResult>
}

/** An intentional, user-safe tool failure that sandbox code is allowed to inspect. */
export class CodeExecutionToolError extends Error {
  override readonly name = "CodeExecutionToolError"
}

const DEFAULT_ACTIVE_TIMEOUT_MS = 30_000
const DEFAULT_MEMORY_LIMIT_BYTES = 64 * 1024 * 1024
const DEFAULT_MAX_STACK_SIZE_BYTES = 1024 * 1024
const EXECUTION_FILENAME = "codevisor-code-executor.js"
const FENCED_CODE_BLOCK = /```(?:[^\n`]*)?\s*\n([\s\S]*?)```/i
const FUNCTION_DECLARATION = /^(?:async\s+)?function(?:\s+([a-zA-Z_$][a-zA-Z0-9_$]*))?\s*\(/
const CALLABLE_ERROR = "Code must evaluate to a function"

class ActiveExecutionBudget {
  private remainingMs: number
  private activeSince: number | undefined

  constructor(readonly limitMs: number) {
    this.remainingMs = limitMs
  }

  exhausted(): boolean {
    if (this.remainingMs <= 0) return true
    return (
      this.activeSince !== undefined && performance.now() - this.activeSince >= this.remainingMs
    )
  }

  run<A>(operation: () => A): A {
    if (this.exhausted()) throw new Error(timeoutMessage(this.limitMs))
    this.activeSince = performance.now()
    try {
      return operation()
    } finally {
      this.remainingMs = Math.max(0, this.remainingMs - (performance.now() - this.activeSince))
      this.activeSince = undefined
    }
  }
}

const timeoutMessage = (timeoutMs: number): string =>
  `QuickJS active execution timed out after ${timeoutMs}ms`

const cancellationMessage = (): string => "QuickJS execution was cancelled"

const toError = (cause: unknown): Error =>
  cause instanceof Error ? cause : new Error(String(cause))

const toErrorMessage = (cause: unknown): string => {
  if (typeof cause === "object" && cause !== null) {
    const message =
      "message" in cause && typeof cause.message === "string" ? cause.message : undefined
    if (message) return message
    const stack = "stack" in cause && typeof cause.stack === "string" ? cause.stack : undefined
    if (stack) return stack
  }
  const error = toError(cause)
  return error.stack ?? error.message
}

const normalizeExecutionError = (
  cause: unknown,
  budget: ActiveExecutionBudget,
  signal?: AbortSignal
): string => {
  if (signal?.aborted === true) return cancellationMessage()
  const message = toErrorMessage(cause)
  return budget.exhausted() && /\binterrupted\b/i.test(message)
    ? timeoutMessage(budget.limitMs)
    : message
}

const serializeJson = (value: unknown, label: string): string | undefined => {
  if (value === undefined) return undefined
  try {
    return JSON.stringify(value)
  } catch (cause) {
    throw new Error(`${label} is not JSON serializable: ${toError(cause).message}`)
  }
}

const extractCandidateSource = (code: string): string => {
  const trimmed = code.trim()
  if (trimmed.length === 0) return ""
  return (trimmed.match(FENCED_CODE_BLOCK)?.[1] ?? trimmed).trim()
}

const wrapCallableBody = (source: string): string =>
  [
    "const __fn = (",
    source,
    ");",
    `if (typeof __fn !== "function") throw new Error(${JSON.stringify(CALLABLE_ERROR)});`,
    "return await __fn();"
  ].join("\n")

const wrapNamedFunctionBody = (source: string, name: string): string =>
  [source, `return await ${name}();`].join("\n")

const wrapAnonymousFunctionBody = (source: string): string => `return await (${source})();`

interface SourceNode {
  readonly type: string
  readonly start?: number | null
  readonly end?: number | null
  readonly id?: { readonly name?: string | null } | null
  readonly expression?: unknown
}

const sliceNode = (source: string, node: SourceNode): string =>
  source.slice(node.start ?? 0, node.end ?? source.length)

const unwrapExpression = (expression: SourceNode): unknown => {
  switch (expression.type) {
    case "ParenthesizedExpression":
    case "TSAsExpression":
    case "TSSatisfiesExpression":
    case "TSTypeAssertion":
    case "TSNonNullExpression":
    case "TSInstantiationExpression":
      return expression.expression === undefined
        ? expression
        : unwrapExpression(expression.expression as SourceNode)
    default:
      return expression
  }
}

const renderExportDefaultBody = (source: string, declaration: SourceNode): string => {
  if (declaration.type === "FunctionDeclaration") {
    const functionSource = sliceNode(source, declaration)
    const name = declaration.id?.name
    return name === undefined || name === null
      ? wrapAnonymousFunctionBody(functionSource)
      : wrapNamedFunctionBody(functionSource, name)
  }
  const expression = unwrapExpression(declaration) as { readonly type?: string }
  const expressionSource = sliceNode(source, declaration)
  return expression.type === "ArrowFunctionExpression" || expression.type === "FunctionExpression"
    ? wrapCallableBody(expressionSource)
    : `return (${expressionSource});`
}

const renderParsedBody = (source: string): string => {
  const program = parse(source, {
    sourceType: "module",
    allowAwaitOutsideFunction: true,
    allowReturnOutsideFunction: true,
    allowImportExportEverywhere: true,
    plugins: ["typescript"]
  }).program
  if (program.body.length !== 1) return source
  const statement = program.body[0]
  if (statement === undefined) return source
  switch (statement.type) {
    case "ExpressionStatement": {
      const expression = unwrapExpression(statement.expression as SourceNode) as {
        readonly type?: string
      }
      return expression.type === "ArrowFunctionExpression" ||
        expression.type === "FunctionExpression"
        ? wrapCallableBody(source)
        : source
    }
    case "FunctionDeclaration":
      return statement.id?.name === undefined
        ? source
        : wrapNamedFunctionBody(source, statement.id.name)
    case "ExportDefaultDeclaration":
      return renderExportDefaultBody(source, statement.declaration as SourceNode)
    default:
      return source
  }
}

const recoverExecutionBody = (code: string): string => {
  const source = extractCandidateSource(code)
  if (source.length === 0) return ""
  try {
    return renderParsedBody(source)
  } catch {
    const withoutDefaultExport = source.replace(/^export\s+default\s+/, "").trim()
    if (
      (withoutDefaultExport.startsWith("async") || withoutDefaultExport.startsWith("(")) &&
      withoutDefaultExport.includes("=>")
    ) {
      return wrapCallableBody(withoutDefaultExport)
    }
    const name = withoutDefaultExport.match(FUNCTION_DECLARATION)?.[1]
    if (FUNCTION_DECLARATION.test(withoutDefaultExport)) {
      return name === undefined
        ? wrapAnonymousFunctionBody(withoutDefaultExport)
        : wrapNamedFunctionBody(withoutDefaultExport, name)
    }
    return withoutDefaultExport
  }
}

const stripTypeScript = (code: string): string =>
  transform(code, {
    transforms: ["typescript"],
    disableESTransforms: true,
    keepUnusedImports: true
  }).code

const buildExecutionSource = (code: string): string => {
  const body = stripTypeScript(recoverExecutionBody(code))
  return [
    '"use strict";',
    "const __invokeTool = __codevisor_invokeTool;",
    "const __log = __codevisor_log;",
    "try { delete globalThis.__codevisor_invokeTool; } catch {}",
    "try { delete globalThis.__codevisor_log; } catch {}",
    "const __format = (value) => {",
    "  if (typeof value === 'string') return value;",
    "  try { return JSON.stringify(value); } catch { return String(value); }",
    "};",
    "const __outputs = [];",
    "globalThis.__codevisor_outputs = __outputs;",
    "const __isToolFile = (value) => value && typeof value === 'object' && value._tag === 'ToolFile' && typeof value.mimeType === 'string' && value.encoding === 'base64' && typeof value.data === 'string' && typeof value.byteLength === 'number';",
    "const __isText = (value) => value && typeof value === 'object' && value.type === 'text' && typeof value.text === 'string';",
    "const __isImage = (value) => value && typeof value === 'object' && value.type === 'image' && typeof value.data === 'string' && typeof value.mimeType === 'string';",
    "const __isAudio = (value) => value && typeof value === 'object' && value.type === 'audio' && typeof value.data === 'string' && typeof value.mimeType === 'string';",
    "const __isResource = (value) => value && typeof value === 'object' && value.type === 'resource' && value.resource && typeof value.resource === 'object' && typeof value.resource.uri === 'string' && (typeof value.resource.text === 'string' || typeof value.resource.blob === 'string');",
    "const __isResourceLink = (value) => value && typeof value === 'object' && value.type === 'resource_link' && typeof value.uri === 'string' && typeof value.name === 'string';",
    "const __isContent = (value) => __isText(value) || __isImage(value) || __isAudio(value) || __isResource(value) || __isResourceLink(value);",
    "const emit = (value) => {",
    "  if (__isToolFile(value)) { __outputs.push({ type: 'file', file: value }); return; }",
    "  if (__isContent(value)) { __outputs.push({ type: 'content', content: value }); return; }",
    "  __outputs.push({ type: 'content', content: { type: 'text', text: value === undefined ? 'undefined' : value === null ? 'null' : __format(value) } });",
    "};",
    "const __callTool = (path, args = {}) => Promise.resolve(__invokeTool(path, args)).then((raw) => raw === undefined ? undefined : JSON.parse(raw));",
    "const __stringMatcher = (value, label) => { if (typeof value !== 'string') throw new Error(label + ' must be a string'); return value; };",
    "const __textMatcher = (value, label) => value instanceof RegExp ? { regex: value.source, flags: value.flags } : __stringMatcher(value, label);",
    "const __tabId = (tab) => typeof tab === 'string' ? tab : tab && typeof tab.id === 'string' ? tab.id : undefined;",
    "const __selectTab = (tabId) => tabId === undefined ? Promise.resolve() : __callTool('browser.tabs', { action: 'select', id: tabId }).then(() => undefined);",
    "const __callTabTool = (tabId, path, args = {}) => __selectTab(tabId).then(() => __callTool(path, args));",
    "const __locatorDescriptor = (value, label = 'locator') => { if (!value || typeof value !== 'object' || !value.__locator) throw new Error(label + ' must be a Browser locator'); return value.__locator; };",
    "const __locatorLeaf = (kind, value, options = {}) => ({ [kind]: ['label','placeholder','text'].includes(kind) ? __textMatcher(value, kind) : __stringMatcher(value, kind), ...(options.exact === undefined ? {} : { exact: options.exact === true }), ...(kind === 'role' && options.name !== undefined ? { name: __textMatcher(options.name, 'name') } : {}) });",
    "const __withoutFrame = (locator) => Object.fromEntries(Object.entries(locator).filter(([key]) => key !== 'frame'));",
    "const __scopedLocator = (parent, leaf) => ({ ...leaf, ...(parent.frame === undefined ? {} : { frame: parent.frame }), scope: __withoutFrame(parent) });",
    "const __makePlaywrightLocator = (locator, tabId) => {",
    "  const api = {",
    "    __locator: locator,",
    "    all: async () => { const count = await api.count(); return Array.from({ length: count }, (_, index) => __makePlaywrightLocator({ ...locator, index }, tabId)); },",
    "    allTextContents: (options = {}) => __callTabTool(tabId, 'browser.playwright.allTextContents', { locator, timeoutMs: options.timeoutMs }).then(value => value.values),",
    "    count: () => __callTabTool(tabId, 'browser.playwright.count', { locator }).then(value => value.count),",
    "    click: (options = {}) => __callTabTool(tabId, 'browser.playwright.click', { locator, button: options.button, doubleClick: false, force: options.force, modifiers: options.modifiers, timeoutMs: options.timeoutMs }).then(() => undefined),",
    "    dblclick: (options = {}) => __callTabTool(tabId, 'browser.playwright.click', { locator, button: options.button, doubleClick: true, force: options.force, modifiers: options.modifiers, timeoutMs: options.timeoutMs }).then(() => undefined),",
    "    fill: (value, options = {}) => __callTabTool(tabId, 'browser.playwright.fill', { locator, value: String(value), timeoutMs: options.timeoutMs }).then(() => undefined),",
    "    type: (value, options = {}) => __callTabTool(tabId, 'browser.playwright.type', { locator, value: String(value), timeoutMs: options.timeoutMs }).then(() => undefined),",
    "    press: (key, options = {}) => __callTabTool(tabId, 'browser.playwright.press', { locator, key: __stringMatcher(key, 'key'), timeoutMs: options.timeoutMs }).then(() => undefined),",
    "    check: (options = {}) => __callTabTool(tabId, 'browser.playwright.check', { locator, force: options.force, timeoutMs: options.timeoutMs }).then(() => undefined),",
    "    uncheck: (options = {}) => __callTabTool(tabId, 'browser.playwright.uncheck', { locator, force: options.force, timeoutMs: options.timeoutMs }).then(() => undefined),",
    "    setChecked: (checked, options = {}) => { if (typeof checked !== 'boolean') throw new Error('checked must be a boolean'); return __callTabTool(tabId, 'browser.playwright.setChecked', { locator, checked, force: options.force, timeoutMs: options.timeoutMs }).then(() => undefined); },",
    "    selectOption: (value, options = {}) => __callTabTool(tabId, 'browser.playwright.selectOption', { locator, values: Array.isArray(value) ? value : [value], timeoutMs: options.timeoutMs }).then(() => undefined),",
    "    isVisible: () => __callTabTool(tabId, 'browser.playwright.isVisible', { locator }).then(value => value.visible),",
    "    isEnabled: () => __callTabTool(tabId, 'browser.playwright.isEnabled', { locator }).then(value => value.enabled),",
    "    getAttribute: (name, options = {}) => __callTabTool(tabId, 'browser.playwright.getAttribute', { locator, name: __stringMatcher(name, 'attribute name'), timeoutMs: options.timeoutMs }).then(value => value.value),",
    "    innerText: (options = {}) => __callTabTool(tabId, 'browser.playwright.innerText', { locator, timeoutMs: options.timeoutMs }).then(value => value.value),",
    "    textContent: (options = {}) => __callTabTool(tabId, 'browser.playwright.textContent', { locator, timeoutMs: options.timeoutMs }).then(value => value.value),",
    "    evaluate: (fn, arg, options = {}) => { if (typeof fn !== 'function' && typeof fn !== 'string') throw new Error('evaluate expects a function or function source string'); return __callTabTool(tabId, 'browser.playwright.evaluate', { locator, function: String(fn), arg, timeoutMs: options.timeoutMs }).then(value => value.value); },",
    "    downloadMedia: (options = {}) => __callTabTool(tabId, 'browser.playwright.downloadMedia', { locator, timeoutMs: options.timeoutMs }).then(() => undefined),",
    "    waitFor: (options = {}) => __callTabTool(tabId, 'browser.playwright.waitFor', { locator, state: options.state ?? 'visible', timeoutMs: options.timeoutMs }).then(() => undefined),",
    "    first: () => __makePlaywrightLocator({ ...locator, index: 0 }, tabId),",
    "    last: () => __makePlaywrightLocator({ ...locator, index: 'last' }, tabId),",
    "    nth: (index) => { if (!Number.isInteger(index) || index < 0) throw new Error('index must be a non-negative integer'); return __makePlaywrightLocator({ ...locator, index }, tabId); },",
    "    filter: (options = {}) => __makePlaywrightLocator({ ...locator, filters: { ...(options.has === undefined ? {} : { has: __locatorDescriptor(options.has, 'has') }), ...(options.hasNot === undefined ? {} : { hasNot: __locatorDescriptor(options.hasNot, 'hasNot') }), ...(options.hasText === undefined ? {} : { hasText: __textMatcher(options.hasText, 'hasText') }), ...(options.hasNotText === undefined ? {} : { hasNotText: __textMatcher(options.hasNotText, 'hasNotText') }), ...(options.visible === undefined ? {} : { visible: options.visible === true }) } }, tabId),",
    "    and: (other) => __makePlaywrightLocator({ ...locator, and: __locatorDescriptor(other) }, tabId),",
    "    or: (other) => __makePlaywrightLocator({ ...locator, or: __locatorDescriptor(other) }, tabId),",
    "    locator: (selector, options = {}) => __makePlaywrightLocator({ ...__scopedLocator(locator, __locatorLeaf('css', selector)), ...(Object.keys(options).length === 0 ? {} : { filters: { ...(options.has === undefined ? {} : { has: __locatorDescriptor(options.has, 'has') }), ...(options.hasNot === undefined ? {} : { hasNot: __locatorDescriptor(options.hasNot, 'hasNot') }), ...(options.hasText === undefined ? {} : { hasText: __textMatcher(options.hasText, 'hasText') }), ...(options.hasNotText === undefined ? {} : { hasNotText: __textMatcher(options.hasNotText, 'hasNotText') }) } }) }, tabId),",
    "    getByRole: (role, options = {}) => __makePlaywrightLocator(__scopedLocator(locator, __locatorLeaf('role', role, options)), tabId),",
    "    getByLabel: (text, options = {}) => __makePlaywrightLocator(__scopedLocator(locator, __locatorLeaf('label', text, options)), tabId),",
    "    getByPlaceholder: (text, options = {}) => __makePlaywrightLocator(__scopedLocator(locator, __locatorLeaf('placeholder', text, options)), tabId),",
    "    getByTestId: (testId) => __makePlaywrightLocator(__scopedLocator(locator, __locatorLeaf('testId', testId, { exact: true })), tabId),",
    "    getByText: (text, options = {}) => __makePlaywrightLocator(__scopedLocator(locator, __locatorLeaf('text', text, options)), tabId)",
    "  };",
    "  return api;",
    "};",
    "const __makePlaywright = (tabId, frame = undefined) => {",
    "  const make = (leaf) => __makePlaywrightLocator({ ...leaf, ...(frame === undefined ? {} : { frame }) }, tabId);",
    "  return {",
    "    domSnapshot: () => __callTabTool(tabId, 'browser.playwright.domSnapshot', {}),",
    "    locator: (selector) => make(__locatorLeaf('css', selector)),",
    "    getByRole: (role, options = {}) => make(__locatorLeaf('role', role, options)),",
    "    getByLabel: (text, options = {}) => make(__locatorLeaf('label', text, options)),",
    "    getByPlaceholder: (text, options = {}) => make(__locatorLeaf('placeholder', text, options)),",
    "    getByTestId: (testId) => make(__locatorLeaf('testId', testId, { exact: true })),",
    "    getByText: (text, options = {}) => make(__locatorLeaf('text', text, options)),",
    "    ref: (ref) => make(__locatorLeaf('ref', ref)),",
    "    frameLocator: (selector) => __makePlaywright(tabId, [...(frame ?? []), __stringMatcher(selector, 'frame selector')]),",
    "    evaluate: (fn, arg, options = {}) => { if (typeof fn !== 'function' && typeof fn !== 'string') throw new Error('evaluate expects a function or function source string'); return __callTabTool(tabId, 'browser.playwright.evaluate', { function: String(fn), arg, timeoutMs: options.timeoutMs }).then(value => value.value); },",
    "    waitForEvent: async (event, options = {}) => { const value = await __callTabTool(tabId, 'browser.playwright.waitForEvent', { event: __stringMatcher(event, 'event'), timeoutMs: options.timeoutMs }); if (event === 'filechooser') return { isMultiple: () => value.multiple === true, setFiles: (paths, setOptions = {}) => __callTabTool(tabId, 'browser.playwright.fileChooserSetFiles', { chooserId: value.chooserId, paths: Array.isArray(paths) ? paths : [paths], timeoutMs: setOptions.timeoutMs }).then(() => undefined) }; return { path: (pathOptions = {}) => __callTabTool(tabId, 'browser.playwright.downloadPath', { downloadId: value.downloadId, timeoutMs: pathOptions.timeoutMs }).then(result => result.path ?? null) }; },",
    "    waitForTimeout: (timeoutMs) => __callTabTool(tabId, 'browser.playwright.waitForTimeout', { timeoutMs }).then(() => undefined),",
    "    waitForURL: (url, options = {}) => __callTabTool(tabId, 'browser.playwright.waitForURL', { url: __stringMatcher(url, 'url'), timeoutMs: options.timeoutMs, waitUntil: options.waitUntil }).then(() => undefined),",
    "    waitForLoadState: (options = {}) => __callTabTool(tabId, 'browser.playwright.waitForLoadState', { state: options.state, timeoutMs: options.timeoutMs }).then(() => undefined),",
    "    expectNavigation: async (action, options = {}) => { if (typeof action !== 'function') throw new Error('action must be a function'); const result = await action(); if (options.url !== undefined) await __callTabTool(tabId, 'browser.playwright.waitForURL', { url: __stringMatcher(options.url, 'url'), timeoutMs: options.timeoutMs, waitUntil: options.waitUntil }); else await __callTabTool(tabId, 'browser.playwright.waitForLoadState', { state: options.waitUntil === 'commit' ? 'domcontentloaded' : options.waitUntil, timeoutMs: options.timeoutMs }); return result; }",
    "  };",
    "};",
    "const __mouseButton = (button) => button === 2 || button === 'middle' ? 'middle' : button === 3 || button === 'right' ? 'right' : 'left';",
    "const __makeCua = (tabId) => ({",
    "  click: (options) => __callTabTool(tabId, 'browser.mouse_click', { x: options.x, y: options.y, button: __mouseButton(options.button), keypress: options.keypress }).then(() => undefined),",
    "  double_click: (options) => __callTabTool(tabId, 'browser.mouse_click', { x: options.x, y: options.y, button: 'left', doubleClick: true, keypress: options.keypress }).then(() => undefined),",
    "  downloadMedia: (options) => __callTabTool(tabId, 'browser.mouse_download_media', options).then(() => undefined),",
    "  drag: (options) => __callTabTool(tabId, 'browser.mouse_drag', { path: options.path, keys: options.keys }).then(() => undefined),",
    "  keypress: (options) => __callTabTool(tabId, 'browser.press_key', { key: options.keys.join('+') }).then(() => undefined),",
    "  move: (options) => __callTabTool(tabId, 'browser.mouse_move', { x: options.x, y: options.y, keys: options.keys }).then(() => undefined),",
    "  scroll: (options) => __callTabTool(tabId, 'browser.mouse_scroll', { x: options.x, y: options.y, deltaX: options.scrollX, deltaY: options.scrollY, keypress: options.keypress }).then(() => undefined),",
    "  type: (options) => __callTabTool(tabId, 'browser.keyboard_type', { text: options.text }).then(() => undefined)",
    "});",
    "const __makeDomCua = (tabId) => ({",
    "  get_visible_dom: () => __callTabTool(tabId, 'browser.snapshot', {}),",
    "  click: (options) => __callTabTool(tabId, 'browser.click', { target: options.node_id }).then(() => undefined),",
    "  double_click: (options) => __callTabTool(tabId, 'browser.click', { target: options.node_id, doubleClick: true }).then(() => undefined),",
    "  downloadMedia: (options) => __callTabTool(tabId, 'browser.dom_download_media', { target: options.node_id, timeoutMs: options.timeoutMs }).then(() => undefined),",
    "  keypress: (options) => __callTabTool(tabId, 'browser.press_key', { key: options.keys.join('+') }).then(() => undefined),",
    "  scroll: (options) => __callTabTool(tabId, 'browser.dom_scroll', { target: options.node_id, x: options.x, y: options.y }).then(() => undefined),",
    "  type: (options) => __callTabTool(tabId, 'browser.keyboard_type', { text: options.text }).then(() => undefined)",
    "});",
    "const __makeClipboard = (tabId) => ({",
    "  readText: () => __callTabTool(tabId, 'browser.clipboard.readText', {}).then(value => value.text),",
    "  writeText: (text) => __callTabTool(tabId, 'browser.clipboard.writeText', { text: __stringMatcher(text, 'text') }).then(() => undefined),",
    "  read: () => __callTabTool(tabId, 'browser.clipboard.read', {}).then(value => value.items),",
    "  write: (items) => __callTabTool(tabId, 'browser.clipboard.write', { items }).then(() => undefined)",
    "});",
    "const __capabilityDocs = { cdp: 'Raw CDP access scoped to this tab. Call send(method, params?, options?) with the method as the first string argument, for example send(\"Runtime.evaluate\", { expression: \"1 + 1\" }); call readEvents(options?) with afterSequence, methods, limit, target, or timeoutMs.', pageAssets: 'Inventory current page assets with list(), then export selected discovered assets with bundle(options).', viewport: 'Set or reset the browser viewport override.' };",
    "const __makeCapabilities = (tabId) => {",
    "  const values = {",
    "    cdp: { send: (method, params = {}, options = {}) => __callTabTool(tabId, 'browser.cdp.send', { method: __stringMatcher(method, 'method'), params, target: options.target, timeoutMs: options.timeoutMs }).then(value => value.result), readEvents: (options = {}) => __callTabTool(tabId, 'browser.cdp.readEvents', options) },",
    "    pageAssets: { list: () => __callTabTool(tabId, 'browser.pageAssets.list', {}), bundle: (options) => __callTabTool(tabId, 'browser.pageAssets.bundle', options) }",
    "  };",
    "  return { list: async () => [{ id: 'cdp', description: __capabilityDocs.cdp }, { id: 'pageAssets', description: __capabilityDocs.pageAssets }], get: async (id) => { const value = values[id]; if (!value) throw new Error('Unsupported tab capability: ' + id); return { ...value, documentation: async () => __capabilityDocs[id] }; } };",
    "};",
    "const __makeBrowserCapabilities = () => ({ list: async () => [{ id: 'viewport', description: __capabilityDocs.viewport }], get: async (id) => { if (id !== 'viewport') throw new Error('Unsupported browser capability: ' + id); return { set: (options) => __callTool('browser.viewport.set', options).then(() => undefined), reset: () => __callTool('browser.viewport.reset', {}).then(() => undefined), documentation: async () => __capabilityDocs.viewport }; } });",
    "const __makeJsDialog = (tabId, dialog) => dialog == null ? undefined : ({ type: dialog.type, accept: (promptText) => __callTabTool(tabId, 'browser.dialog', { accept: true, ...(promptText === undefined ? {} : { promptText }) }).then(() => undefined), dismiss: () => __callTabTool(tabId, 'browser.dialog', { accept: false }).then(() => undefined) });",
    "const __makeTab = (info = {}) => {",
    "  const tabId = __tabId(info);",
    "  return {",
    "    ...(tabId === undefined ? {} : { id: tabId }),",
    "    playwright: __makePlaywright(tabId),",
    "    cua: __makeCua(tabId),",
    "    dom_cua: __makeDomCua(tabId),",
    "    clipboard: __makeClipboard(tabId),",
    "    capabilities: __makeCapabilities(tabId),",
    "    dev: { logs: (options = {}) => __callTabTool(tabId, 'browser.dev.logs', options).then(value => value.entries) },",
    "    getJsDialog: () => __callTabTool(tabId, 'browser.getJsDialog', {}).then(value => __makeJsDialog(tabId, value.dialog)),",
    "    goto: (url) => __callTabTool(tabId, 'browser.navigate', { url: __stringMatcher(url, 'url') }).then(() => undefined),",
    "    back: () => __callTabTool(tabId, 'browser.back', {}).then(() => undefined),",
    "    forward: () => __callTabTool(tabId, 'browser.forward', {}).then(() => undefined),",
    "    reload: () => __callTabTool(tabId, 'browser.reload', {}).then(() => undefined),",
    "    markDeliverable: () => __callTool('browser.markTab', { ...(tabId === undefined ? {} : { id: tabId }), status: 'deliverable' }).then(() => undefined),",
    "    markHandoff: () => __callTool('browser.markTab', { ...(tabId === undefined ? {} : { id: tabId }), status: 'handoff' }).then(() => undefined),",
    "    close: () => __callTool('browser.tabs', { action: 'close', ...(tabId === undefined ? {} : { id: tabId }) }).then(() => undefined),",
    "    screenshot: (options = {}) => __callTabTool(tabId, 'browser.screenshot', options),",
    "    title: () => __callTabTool(tabId, 'browser.tab_info', {}).then(value => value.title),",
    "    url: () => __callTabTool(tabId, 'browser.tab_info', {}).then(value => value.url)",
    "  };",
    "};",
    "const __tabInfo = (tab) => ({ id: tab.id, ...(tab.index === undefined ? {} : { index: tab.index }), ...(tab.title === undefined ? {} : { title: tab.title }), ...(tab.url === undefined ? {} : { url: tab.url }) });",
    "const __tabs = (...args) => __callTool('browser.tabs', args[0]);",
    "__tabs.new = () => __callTool('browser.tabs', { action: 'new' }).then(result => __makeTab(result.tabs.find(tab => tab.selected) || {}));",
    "__tabs.list = () => __callTool('browser.tabs', { action: 'list' }).then(result => result.tabs.map(__tabInfo));",
    "__tabs.get = (id) => __callTool('browser.tabs', { action: 'select', id: __stringMatcher(id, 'tab id') }).then(() => __makeTab({ id }));",
    "__tabs.selected = () => __callTool('browser.tabs', { action: 'list' }).then(result => { const selected = result.tabs.find(tab => tab.selected); return selected ? __makeTab(selected) : undefined; });",
    "__tabs.finalize = (options = {}) => { const keep = Array.isArray(options.keep) ? options.keep : []; return __callTool('browser.finalizeTabs', { native: true, keepIds: keep.map(item => __tabId(item.tab)).filter(Boolean) }).then(() => undefined); };",
    "__tabs.content = async () => { throw new Error('tabs.content is not supported by Codevisor\\'s CDP browser backends'); };",
    "const __user = {",
    "  openTabs: () => __callTool('browser.openTabs', {}).then(result => result.tabs.map(__tabInfo)),",
    "  claimTab: (tab) => { const id = __tabId(tab); if (id === undefined) throw new Error('claimTab expects a tab returned by openTabs'); return __callTool('browser.claimTab', { id }).then(() => __makeTab({ id })); },",
    "  history: (options = {}) => __callTool('browser.user.history', options).then(value => value.entries)",
    "};",
    "const __browserTab = __makeTab();",
    "const __browserCore = { browserId: 'codevisor', capabilities: __makeBrowserCapabilities(), tab: __browserTab, tabs: __tabs, user: __user, documentation: async () => 'Codevisor Browser exposes native-shaped tabs, Playwright locators, clipboard, developer logs, user history, and optional viewport, CDP, and page-assets capabilities through tools.browser.', nameSession: (_name) => Promise.resolve() };",
    "const __browser = new Proxy(__browserCore, { get(target, prop) { if (prop === 'then' || typeof prop === 'symbol') return undefined; if (prop in target) return target[prop]; return __makeToolsProxy(['browser', String(prop)]); } });",
    "const __enumerationError = (path) => new Error((path.length === 0 ? 'tools' : 'tools.' + path.join('.')) + ' is a lazy proxy and cannot be enumerated. Use tools.search({ query: \"...\" }) to find tools.');",
    "const __makeToolsProxy = (path = []) => new Proxy(() => undefined, {",
    "  get(_target, prop) {",
    "    if (prop === 'then' || typeof prop === 'symbol') return undefined;",
    "    const nextPath = [...path, String(prop)];",
    "    if (nextPath.length === 1 && nextPath[0] === 'browser') return __browser;",
    "    return __makeToolsProxy(nextPath);",
    "  },",
    "  ownKeys() { throw __enumerationError(path); },",
    "  getOwnPropertyDescriptor() { throw __enumerationError(path); },",
    "  apply(_target, _thisArg, args) {",
    "    const toolPath = path.join('.');",
    "    if (!toolPath) throw new Error('Tool path missing in invocation');",
    "    return __callTool(toolPath, args[0]);",
    "  }",
    "});",
    "const tools = __makeToolsProxy();",
    "const console = {",
    "  log: (...args) => __log('log', args.map(__format).join(' ')),",
    "  warn: (...args) => __log('warn', args.map(__format).join(' ')),",
    "  error: (...args) => __log('error', args.map(__format).join(' ')),",
    "  info: (...args) => __log('info', args.map(__format).join(' ')),",
    "  debug: (...args) => __log('debug', args.map(__format).join(' '))",
    "};",
    "const fetch = () => { throw new Error('fetch is disabled in Codevisor code execution'); };",
    "(async () => {",
    body,
    "})()"
  ].join("\n")
}

const readPropDump = (context: QuickJSContext, handle: QuickJSHandle, key: string): unknown => {
  const property = context.getProp(handle, key)
  try {
    return context.dump(property)
  } finally {
    property.dispose()
  }
}

const readOutputItems = (context: QuickJSContext): ReadonlyArray<unknown> | undefined => {
  const output = readPropDump(context, context.global, "__codevisor_outputs")
  return Array.isArray(output) && output.length > 0 ? output : undefined
}

const readResultState = (
  context: QuickJSContext,
  handle: QuickJSHandle
): { readonly settled: boolean; readonly value: unknown; readonly error: unknown } => ({
  settled: readPropDump(context, handle, "settled") === true,
  value: readPropDump(context, handle, "value"),
  error: readPropDump(context, handle, "error")
})

const createLogBridge = (context: QuickJSContext, logs: Array<string>): QuickJSHandle =>
  context.newFunction("__codevisor_log", (levelHandle, lineHandle) => {
    logs.push(`[${context.getString(levelHandle)}] ${context.getString(lineHandle)}`)
    return context.undefined
  })

const sandboxToolErrorMessage = (cause: unknown): string =>
  cause instanceof CodeExecutionToolError ? cause.message : "Internal tool error"

const createToolBridge = (
  context: QuickJSContext,
  toolInvoker: CodeToolInvoker,
  pendingDeferreds: Set<QuickJSDeferredPromise>
): QuickJSHandle =>
  context.newFunction("__codevisor_invokeTool", (pathHandle, argsHandle) => {
    const path = context.getString(pathHandle)
    const args =
      argsHandle === undefined || context.typeof(argsHandle) === "undefined"
        ? undefined
        : context.dump(argsHandle)
    const deferred = context.newPromise()
    pendingDeferreds.add(deferred)
    void deferred.settled.then(
      () => pendingDeferreds.delete(deferred),
      () => pendingDeferreds.delete(deferred)
    )
    void Promise.resolve()
      .then(() => toolInvoker.invoke({ path, args }))
      .then(
        (value) => {
          if (!deferred.alive) return
          try {
            const serialized = serializeJson(value, `Tool result for ${path}`)
            if (serialized === undefined) {
              deferred.resolve()
              return
            }
            const valueHandle = context.newString(serialized)
            deferred.resolve(valueHandle)
            valueHandle.dispose()
          } catch (cause) {
            const errorHandle = context.newError(toErrorMessage(cause))
            deferred.reject(errorHandle)
            errorHandle.dispose()
          }
        },
        (cause) => {
          if (!deferred.alive) return
          const errorHandle = context.newError(sandboxToolErrorMessage(cause))
          deferred.reject(errorHandle)
          errorHandle.dispose()
        }
      )
    return deferred.handle
  })

const drainJobs = (
  context: QuickJSContext,
  runtime: QuickJSRuntime,
  budget: ActiveExecutionBudget,
  signal?: AbortSignal
): void => {
  while (runtime.hasPendingJob()) {
    signal?.throwIfAborted()
    const pending = budget.run(() => runtime.executePendingJobs())
    if (pending.error !== undefined) {
      const error = context.dump(pending.error)
      pending.error.dispose()
      throw toError(error)
    }
  }
}

const waitForDeferred = async (
  pendingDeferreds: ReadonlySet<QuickJSDeferredPromise>,
  signal?: AbortSignal
): Promise<void> => {
  signal?.throwIfAborted()
  const settled = Promise.race([...pendingDeferreds].map((deferred) => deferred.settled))
  if (signal === undefined) return settled
  await new Promise<void>((resolve, reject) => {
    let finished = false
    const finish = (operation: () => void): void => {
      if (finished) return
      finished = true
      signal.removeEventListener("abort", onAbort)
      operation()
    }
    const onAbort = (): void =>
      finish(() => reject(signal.reason ?? new Error(cancellationMessage())))
    signal.addEventListener("abort", onAbort, { once: true })
    if (signal.aborted) onAbort()
    void settled.then(
      () => finish(resolve),
      (cause) => finish(() => reject(cause))
    )
  })
}

const drainAsync = async (
  context: QuickJSContext,
  runtime: QuickJSRuntime,
  pendingDeferreds: ReadonlySet<QuickJSDeferredPromise>,
  budget: ActiveExecutionBudget,
  signal?: AbortSignal
): Promise<void> => {
  drainJobs(context, runtime, budget, signal)
  while (pendingDeferreds.size > 0) {
    await waitForDeferred(pendingDeferreds, signal)
    drainJobs(context, runtime, budget, signal)
  }
  drainJobs(context, runtime, budget, signal)
}

const evaluate = async (
  executorOptions: CodeExecutorOptions,
  code: string,
  toolInvoker: CodeToolInvoker,
  executeOptions: ExecuteCodeOptions
): Promise<CodeExecutionResult> => {
  const activeTimeoutMs = Math.max(
    100,
    executorOptions.activeTimeoutMs ?? DEFAULT_ACTIVE_TIMEOUT_MS
  )
  const budget = new ActiveExecutionBudget(activeTimeoutMs)
  const signal = executeOptions.signal
  const logs: Array<string> = []
  const pendingDeferreds = new Set<QuickJSDeferredPromise>()
  const QuickJS = await getQuickJS()
  const runtime = QuickJS.newRuntime()
  try {
    runtime.setMemoryLimit(executorOptions.memoryLimitBytes ?? DEFAULT_MEMORY_LIMIT_BYTES)
    runtime.setMaxStackSize(executorOptions.maxStackSizeBytes ?? DEFAULT_MAX_STACK_SIZE_BYTES)
    runtime.setInterruptHandler(() => budget.exhausted() || signal?.aborted === true)
    const context = runtime.newContext()
    try {
      signal?.throwIfAborted()
      const logBridge = createLogBridge(context, logs)
      context.setProp(context.global, "__codevisor_log", logBridge)
      logBridge.dispose()
      const toolBridge = createToolBridge(context, toolInvoker, pendingDeferreds)
      context.setProp(context.global, "__codevisor_invokeTool", toolBridge)
      toolBridge.dispose()

      const evaluated = budget.run(() =>
        context.evalCode(buildExecutionSource(code), EXECUTION_FILENAME)
      )
      if (evaluated.error !== undefined) {
        const error = context.dump(evaluated.error)
        evaluated.error.dispose()
        return { result: null, error: normalizeExecutionError(error, budget, signal), logs }
      }
      context.setProp(context.global, "__codevisor_result", evaluated.value)
      evaluated.value.dispose()

      const stateResult = budget.run(() =>
        context.evalCode(
          "(function(p){ const state = { value: undefined, error: undefined, settled: false }; const formatError = (error) => { if (error && typeof error === 'object') { const message = typeof error.message === 'string' ? error.message : ''; const stack = typeof error.stack === 'string' ? error.stack : ''; if (message && stack) return stack.includes(message) ? stack : message + '\\n' + stack; if (message) return message; if (stack) return stack; } return String(error); }; p.then((value) => { state.value = value; state.settled = true; }, (error) => { state.error = formatError(error); state.settled = true; }); return state; })(__codevisor_result)"
        )
      )
      if (stateResult.error !== undefined) {
        const error = context.dump(stateResult.error)
        stateResult.error.dispose()
        return { result: null, error: normalizeExecutionError(error, budget, signal), logs }
      }
      const stateHandle = stateResult.value
      try {
        await drainAsync(context, runtime, pendingDeferreds, budget, signal)
        const state = readResultState(context, stateHandle)
        const output = readOutputItems(context)
        if (!state.settled) {
          return {
            result: null,
            error: timeoutMessage(activeTimeoutMs),
            ...(output === undefined ? {} : { output }),
            logs
          }
        }
        if (state.error !== undefined) {
          return {
            result: null,
            error: normalizeExecutionError(state.error, budget, signal),
            ...(output === undefined ? {} : { output }),
            logs
          }
        }
        return { result: state.value, ...(output === undefined ? {} : { output }), logs }
      } finally {
        stateHandle.dispose()
      }
    } finally {
      for (const deferred of pendingDeferreds) {
        if (deferred.alive) deferred.dispose()
      }
      pendingDeferreds.clear()
      context.dispose()
    }
  } catch (cause) {
    return { result: null, error: normalizeExecutionError(cause, budget, signal), logs }
  } finally {
    runtime.dispose()
  }
}

export const makeCodeExecutor = (options: CodeExecutorOptions = {}): CodeExecutor => ({
  execute: (code, toolInvoker, executeOptions = {}) =>
    evaluate(options, code, toolInvoker, executeOptions)
})
