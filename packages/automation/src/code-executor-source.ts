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
import { transform } from "sucrase"
import { browserDocumentation } from "./browser-documentation.js"
import { computerUseCellBody } from "./computer-use-repl-source.js"

/// Turning the model's code into an executable source: fenced-block
/// extraction, callable recovery (parsed, then regex fallback), TypeScript
/// stripping, and the sandbox wrapper that exposes tools/log/emit.

const FENCED_CODE_BLOCK = /```(?:[^\n`]*)?\s*\n([\s\S]*?)```/i
const FUNCTION_DECLARATION = /^(?:async\s+)?function(?:\s+([a-zA-Z_$][a-zA-Z0-9_$]*))?\s*\(/
const CALLABLE_ERROR = "Code must evaluate to a function"

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

export const buildExecutionSource = (code: string, persistent = false): string => {
  const body = persistent ? computerUseCellBody(code) : stripTypeScript(recoverExecutionBody(code))
  return [
    ...(persistent ? ["(async () => {"] : []),
    '"use strict";',
    persistent
      ? "const __invokeTool = (...args) => globalThis.__codevisor_invokeTool(...args);"
      : "const __invokeTool = __codevisor_invokeTool;",
    "const __log = __codevisor_log;",
    ...(persistent ? [] : ["try { delete globalThis.__codevisor_invokeTool; } catch {}"]),
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
    "const __callTabTool = (tabId, path, args = {}) => __callTool(path, { ...args, ...(tabId === undefined ? {} : { tabId }) });",
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
    "    evaluateAll: (fn, arg, options = {}) => __callTabTool(tabId, 'browser.playwright.evaluateAll', { locator, function: String(fn), arg, timeoutMs: options.timeoutMs }).then(value => value.value),",
    "    pressSequentially: (value, options = {}) => __callTabTool(tabId, 'browser.playwright.pressSequentially', { locator, value: String(value), timeoutMs: options.timeoutMs }).then(() => undefined),",
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
    "const __PASSTHROUGH_PROPS = new Set(['then', 'catch', 'finally', 'toJSON', 'constructor', 'valueOf', 'toString', 'toLocaleString', 'hasOwnProperty', 'isPrototypeOf', 'propertyIsEnumerable', '__proto__', 'asymmetricMatch', '$$typeof', 'nodeType', 'inspect', 'length']);",
    "const __strict = (name, target) => new Proxy(target, { get(object, prop, receiver) { if (typeof prop === 'symbol' || __PASSTHROUGH_PROPS.has(prop) || prop in object) return Reflect.get(object, prop, receiver); throw new Error(name + '.' + String(prop) + ' is not supported by Codevisor Browser; available: ' + Object.keys(object).join(', ')); } });",
    "const __mouseButton = (button) => button === 2 || button === 'middle' ? 'middle' : button === 3 || button === 'right' ? 'right' : 'left';",
    "const __makeMouse = (tabId) => __strict('tab.playwright.mouse', {",
    "  move: (x, y, options = {}) => __callTabTool(tabId, 'browser.mouse_move', { x, y, steps: options.steps }).then(() => undefined),",
    "  down: (options = {}) => __callTabTool(tabId, 'browser.mouse_down', { button: __mouseButton(options.button), clickCount: options.clickCount }).then(() => undefined),",
    "  up: (options = {}) => __callTabTool(tabId, 'browser.mouse_up', { button: __mouseButton(options.button), clickCount: options.clickCount }).then(() => undefined),",
    "  click: (x, y, options = {}) => __callTabTool(tabId, 'browser.mouse_click', { x, y, button: __mouseButton(options.button), doubleClick: options.clickCount === 2 }).then(() => undefined),",
    "  dblclick: (x, y, options = {}) => __callTabTool(tabId, 'browser.mouse_click', { x, y, button: __mouseButton(options.button), doubleClick: true }).then(() => undefined),",
    "  wheel: (deltaX, deltaY) => __callTabTool(tabId, 'browser.mouse_scroll', { deltaX, deltaY }).then(() => undefined)",
    "});",
    "const __makeKeyboard = (tabId) => __strict('tab.playwright.keyboard', {",
    "  press: (key) => __callTabTool(tabId, 'browser.press_key', { key: __stringMatcher(key, 'key') }).then(() => undefined),",
    "  down: (key) => __callTabTool(tabId, 'browser.key_down', { key: __stringMatcher(key, 'key') }).then(() => undefined),",
    "  up: (key) => __callTabTool(tabId, 'browser.key_up', { key: __stringMatcher(key, 'key') }).then(() => undefined),",
    "  type: (text) => __callTabTool(tabId, 'browser.keyboard_type', { text: __stringMatcher(text, 'text'), mode: 'keys' }).then(() => undefined),",
    "  insertText: (text) => __callTabTool(tabId, 'browser.keyboard_type', { text: __stringMatcher(text, 'text') }).then(() => undefined)",
    "});",
    "const __makePlaywright = (tabId, frame = undefined) => {",
    "  const make = (leaf) => __makePlaywrightLocator({ ...leaf, ...(frame === undefined ? {} : { frame }) }, tabId);",
    "  return __strict(frame === undefined ? 'tab.playwright' : 'frameLocator', {",
    "    ...(frame === undefined ? { mouse: __makeMouse(tabId), keyboard: __makeKeyboard(tabId) } : {}),",
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
    "    expectNavigation: async (action, options = {}) => { if (typeof action !== 'function') throw new Error('action must be a function'); const baseline = await __callTabTool(tabId, 'browser.playwright.armNavigation'); const result = await action(); await __callTabTool(tabId, 'browser.playwright.waitForNavigation', { ...baseline, ...options }); return result; }",
    "  });",
    "};",
    "const __makeCua = (tabId) => __strict('tab.cua', {",
    "  click: (options) => __callTabTool(tabId, 'browser.mouse_click', { x: options.x, y: options.y, button: __mouseButton(options.button), keypress: options.keypress }).then(() => undefined),",
    "  double_click: (options) => __callTabTool(tabId, 'browser.mouse_click', { x: options.x, y: options.y, button: 'left', doubleClick: true, keypress: options.keypress }).then(() => undefined),",
    "  downloadMedia: (options) => __callTabTool(tabId, 'browser.mouse_download_media', options).then(() => undefined),",
    "  drag: (options) => __callTabTool(tabId, 'browser.mouse_drag', { path: options.path, keys: options.keys }).then(() => undefined),",
    "  keypress: (options) => __callTabTool(tabId, 'browser.press_key', { key: options.keys.join('+') }).then(() => undefined),",
    "  move: (options) => __callTabTool(tabId, 'browser.mouse_move', { x: options.x, y: options.y, keys: options.keys }).then(() => undefined),",
    "  scroll: (options) => __callTabTool(tabId, 'browser.mouse_scroll', { x: options.x, y: options.y, deltaX: options.scrollX, deltaY: options.scrollY, keypress: options.keypress }).then(() => undefined),",
    "  type: (options) => __callTabTool(tabId, 'browser.keyboard_type', { text: options.text }).then(() => undefined)",
    "});",
    "const __makeDomCua = (tabId) => __strict('tab.dom_cua', {",
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
    "const __capabilityDocs = { cdp: 'Raw CDP access scoped to this tab. Call send(method, params?, options?) with the method as the first string argument, for example send(\"Runtime.evaluate\", { expression: \"1 + 1\" }); call readEvents(options?) with afterSequence, methods, limit, target, or timeoutMs.', pageAssets: 'Inventory current page assets with list(), then export selected discovered assets with bundle(options).', viewport: 'Set or reset the browser viewport override.', tabGroups: 'Chrome tab groups in the user\\'s browser: list(), ensure({ tabs, title, color }) which reuses a same-titled group, create({ tabs, title, color }), add(group, tabs), update(group, { title, color, collapsed }), ungroup(tabs). Also available directly as browser.tabGroups.' };",
    "const __makeCapabilities = (tabId) => {",
    "  const values = {",
    "    cdp: { send: (method, params = {}, options = {}) => __callTabTool(tabId, 'browser.cdp.send', { method: __stringMatcher(method, 'method'), params, target: options.target, timeoutMs: options.timeoutMs }).then(value => value.result), readEvents: (options = {}) => __callTabTool(tabId, 'browser.cdp.readEvents', options) },",
    "    pageAssets: { list: () => __callTabTool(tabId, 'browser.pageAssets.list', {}), bundle: (options) => __callTabTool(tabId, 'browser.pageAssets.bundle', options) }",
    "  };",
    "  return { list: async () => [{ id: 'cdp', description: __capabilityDocs.cdp }, { id: 'pageAssets', description: __capabilityDocs.pageAssets }], get: async (id) => { const value = values[id]; if (!value) throw new Error('Unsupported tab capability: ' + id); return { ...value, documentation: async () => __capabilityDocs[id] }; } };",
    "};",
    "const __makeBrowserCapabilities = () => ({ list: async () => [{ id: 'viewport', description: __capabilityDocs.viewport }, { id: 'tabGroups', description: __capabilityDocs.tabGroups }], get: async (id) => { if (id === 'tabGroups') return { ...__tabGroups, documentation: async () => __capabilityDocs.tabGroups }; if (id !== 'viewport') throw new Error('Unsupported browser capability: ' + id); return { set: (options) => __callTool('browser.viewport.set', options).then(() => undefined), reset: () => __callTool('browser.viewport.reset', {}).then(() => undefined), documentation: async () => __capabilityDocs.viewport }; } });",
    "const __makeJsDialog = (tabId, dialog) => dialog == null ? undefined : ({ type: dialog.type, accept: (promptText) => __callTabTool(tabId, 'browser.dialog', { accept: true, ...(promptText === undefined ? {} : { promptText }) }).then(() => undefined), dismiss: () => __callTabTool(tabId, 'browser.dialog', { accept: false }).then(() => undefined) });",
    "const __makeTab = (info = {}) => {",
    "  const tabId = __tabId(info);",
    "  return __strict('tab', {",
    "    id: tabId,",
    "    getAXState: () => __callTabTool(tabId, 'browser.snapshot'),",
    "    click: (ref, options = {}) => __callTabTool(tabId, 'browser.click', { ...options, target: ref }),",
    "    fill: (ref, text) => __callTabTool(tabId, 'browser.type', { target: ref, text, submit: false }),",
    "    pressKey: (key) => __callTabTool(tabId, 'browser.press_key', { key }),",
    "    index: info.index,",
    "    info: { id: tabId, index: info.index, title: info.title, url: info.url, selected: info.selected, origin: info.origin, groupId: info.groupId },",
    "    playwright: __makePlaywright(tabId),",
    "    cua: __makeCua(tabId),",
    "    dom_cua: __makeDomCua(tabId),",
    "    clipboard: __makeClipboard(tabId),",
    "    content: { export: (options = {}) => __callTabTool(tabId, 'browser.content.export', options) },",
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
    "  });",
    "};",
    "const __tabs = (...args) => __callTool('browser.tabs', args[0]);",
    "__tabs.new = () => __callTool('browser.tabs', { action: 'new' }).then(result => __makeTab(result.tabs.find(tab => tab.selected) || {}));",
    "__tabs.list = (options = {}) => __callTool('browser.tabs', { action: 'list', ...(options.scope === undefined ? {} : { scope: options.scope }) }).then(result => result.tabs.map(__makeTab));",
    "__tabs.get = (id) => __callTool('browser.tabs', { action: 'select', id: __stringMatcher(id, 'tab id') }).then(() => __makeTab({ id }));",
    "__tabs.selected = () => __callTool('browser.tabs', { action: 'list' }).then(result => { const selected = result.tabs.find(tab => tab.selected); return selected ? __makeTab(selected) : undefined; });",
    "const __keepEntry = (item, index) => {",
    "  const wrapped = item !== null && typeof item === 'object' && 'tab' in item;",
    "  const id = __tabId(wrapped ? item.tab : item);",
    "  if (id === undefined) throw new Error('tabs.finalize keep[' + index + '] must be a tab, a tab id, or { tab, status }');",
    "  const status = wrapped ? item.status : undefined;",
    "  if (status !== undefined && status !== 'deliverable' && status !== 'handoff') throw new Error('tabs.finalize keep[' + index + '].status must be deliverable or handoff');",
    "  return { id, status };",
    "};",
    "__tabs.finalize = async (options = {}) => {",
    "  if (options === null || typeof options !== 'object') throw new Error('tabs.finalize expects an options object');",
    "  if (options.keep !== undefined && !Array.isArray(options.keep)) throw new Error('tabs.finalize keep must be an array of tabs or { tab, status } entries');",
    "  const entries = (options.keep ?? []).map(__keepEntry);",
    "  for (const entry of entries) if (entry.status !== undefined) await __callTool('browser.markTab', { id: entry.id, status: entry.status });",
    "  const result = await __callTool('browser.finalizeTabs', { native: true, keepIds: entries.map(entry => entry.id) });",
    "  return { kept: result.kept ?? [], closed: result.closed ?? [], released: result.released ?? [] };",
    "};",
    "__tabs.content = async () => { throw new Error('tabs.content is not supported by Codevisor\\'s CDP browser backends'); };",
    "const __user = {",
    "  openTabs: () => __callTool('browser.openTabs', {}).then(result => result.tabs.map(__makeTab)),",
    "  claimTab: (tab) => { const id = __tabId(tab); if (id === undefined) throw new Error('claimTab expects a tab returned by openTabs'); return __callTool('browser.claimTab', { id, title: tab.info?.title ?? tab.title, url: tab.info?.url ?? tab.url }).then(() => __makeTab({ id })); },",
    "  history: (options = {}) => __callTool('browser.user.history', options).then(value => value.entries)",
    "};",
    "const __tabGroupTabIds = (tabs) => { if (!Array.isArray(tabs) || tabs.length === 0) throw new Error('tabGroups expects a non-empty array of tabs or tab ids'); return tabs.map((tab, index) => { const id = __tabId(tab); if (id === undefined) throw new Error('tabGroups tabs[' + index + '] must be a tab or a tab id'); return id; }); };",
    "const __tabGroupId = (group) => { const id = typeof group === 'number' ? group : group !== null && typeof group === 'object' && typeof group.id === 'number' ? group.id : undefined; if (id === undefined) throw new Error('tabGroups expects a group returned by tabGroups or its numeric id'); return id; };",
    "const __tabGroups = __strict('browser.tabGroups', {",
    "  list: () => __callTool('browser.tab_groups', { action: 'list' }).then(result => result.groups),",
    "  create: (options = {}) => __callTool('browser.tab_groups', { action: 'create', tabIds: __tabGroupTabIds(options.tabs), title: options.title, color: options.color }).then(result => result.group),",
    "  ensure: (options = {}) => __callTool('browser.tab_groups', { action: 'ensure', tabIds: __tabGroupTabIds(options.tabs), title: __stringMatcher(options.title, 'title'), color: options.color }).then(result => result.group),",
    "  add: (group, tabs) => __callTool('browser.tab_groups', { action: 'add', groupId: __tabGroupId(group), tabIds: __tabGroupTabIds(tabs) }).then(result => result.group),",
    "  update: (group, options = {}) => __callTool('browser.tab_groups', { action: 'update', groupId: __tabGroupId(group), title: options.title, color: options.color, collapsed: options.collapsed }).then(result => result.group),",
    "  ungroup: (tabs) => __callTool('browser.tab_groups', { action: 'ungroup', tabIds: __tabGroupTabIds(tabs) }).then(() => undefined)",
    "});",
    "const __browserTab = __makeTab();",
    `const __browserCore = { browserId: 'codevisor', capabilities: __makeBrowserCapabilities(), tab: __browserTab, tabs: __tabs, tabGroups: __tabGroups, user: __user, documentation: async () => ${JSON.stringify(browserDocumentation)}, nameSession: (name) => __callTool('browser.nameSession', { name: __stringMatcher(name, 'name') }).then(() => undefined) };`,
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
    ...(persistent
      ? ["globalThis.browser ??= __browser; globalThis.browser.write = emit;"]
      : ["(async () => {"]),
    body,
    "})()"
  ].join("\n")
}

export const buildBrowserReplSource = (code: string): string => buildExecutionSource(code, true)
