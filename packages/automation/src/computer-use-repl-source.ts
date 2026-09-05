import { parse } from "@babel/parser"
import { transform } from "sucrase"

const bindingNames = (value: unknown): string[] => {
  if (!value || typeof value !== "object") return []
  const node = value as Record<string, unknown>
  if (node.type === "Identifier") return [String(node.name)]
  if (node.type === "RestElement") return bindingNames(node.argument)
  if (node.type === "AssignmentPattern") return bindingNames(node.left)
  if (node.type === "ArrayPattern") return (node.elements as unknown[]).flatMap(bindingNames)
  if (node.type === "ObjectPattern")
    return (node.properties as Record<string, unknown>[]).flatMap((p) =>
      bindingNames(p.type === "RestElement" ? p.argument : p.value)
    )
  throw new Error("Unsupported REPL binding pattern")
}

/** Async cells use explicit global bindings; declarations inside functions/blocks remain local. */
export const computerUseCellBody = (code: string): string => {
  const source = transform(code, { transforms: ["typescript"], disableESTransforms: true }).code
  const nodes = parse(source, { sourceType: "script", allowAwaitOutsideFunction: true }).program
    .body
  const slice = (node: { start?: number | null; end?: number | null }) =>
    source.slice(node.start ?? 0, node.end ?? source.length)
  const reserve = (name: string) => {
    if (
      ["computer", "browser", "tools", "globalThis"].includes(name) ||
      name.startsWith("__codevisor")
    )
      throw new Error(`Reserved REPL binding: ${name}`)
    return `globalThis[${JSON.stringify(name)}]`
  }
  return nodes
    .map((node, index) => {
      if (node.type === "VariableDeclaration")
        return node.declarations
          .map((declaration) => {
            const names = bindingNames(declaration.id)
            const initialize = names.map((name) => `${reserve(name)} ??= undefined;`).join("\n")
            if (declaration.init === null || declaration.init === undefined) return initialize
            return `${initialize}\n(${slice(declaration.id)} = ${slice(declaration.init)});`
          })
          .join("\n")
      if ((node.type === "FunctionDeclaration" || node.type === "ClassDeclaration") && node.id) {
        return `${reserve(node.id.name)} = ${slice(node)};`
      }
      if (index === nodes.length - 1 && node.type === "ExpressionStatement")
        return `return (${slice(node.expression)});`
      return slice(node)
    })
    .join("\n")
}

const API_SOURCE = String.raw`
if (!globalThis.computer) {
  const call = (name, args = {}) => Promise.resolve(globalThis.__codevisor_invokeTool('computer.' + name, args)).then(raw => raw === undefined ? undefined : JSON.parse(raw));
  const write = (value) => {
    const outputs = globalThis.__codevisor_outputs;
    if (value && value.type === 'image') { outputs.push({ type: 'content', content: value }); return; }
    if (value && typeof value === 'object' && typeof value.text === 'string' && ('snapshotId' in value || 'windows' in value)) {
      const { image, ...state } = value;
      outputs.push({ type: 'content', content: { type: 'text', text: JSON.stringify(state) } });
      if (image) outputs.push({ type: 'content', content: image });
      return;
    }
    outputs.push({ type: 'content', content: { type: 'text', text: typeof value === 'string' ? value : JSON.stringify(value) ?? 'undefined' } });
  };
  const handles = new Map();
  const recordingHandle = (started) => Object.freeze({
    ...started,
    status: () => call('recording_status', { recording_id: started.recordingId }),
    stop: () => call('stop_recording', { recording_id: started.recordingId }),
    toJSON: () => started
  });
  const startRecording = async (options) => recordingHandle(await call('start_recording', options));
  const makeApp = (name, windowId, deliveryMode = 'background') => {
    const info = { name, windowId, snapshotId: undefined };
    const target = (value) => typeof value === 'number' ? { element_index: value } : value && typeof value === 'object' ? value : {};
    const invoke = (method, args = {}, scoped = true) => {
      if (scoped && info.snapshotId === undefined && (args.element_index !== undefined || method === 'click' || method === 'drag')) throw new Error('Observe this window before using an element or screenshot');
      return call(method, { app: info.name, ...(info.windowId === undefined ? {} : { window_id: info.windowId }), ...(scoped && info.snapshotId !== undefined ? { snapshot_id: info.snapshotId } : {}), delivery_mode: deliveryMode, ...args });
    };
    const observe = async (method, options = {}) => {
      const state = await call(method, { app: info.name, ...(windowId === undefined ? {} : { window_id: windowId }), ...options });
      info.name = state.resolvedApp?.id ?? info.name;
      info.windowId = state.windowId;
      info.snapshotId = state.snapshotId;
      if (method === 'wait_for' && state.matched === false) { write(state); throw new Error('Timed out waiting for the requested app state'); }
      return state;
    };
    const endpoint = (prefix, value) => typeof value === 'number' ? { [prefix + '_element_index']: value } : { [prefix + '_x']: value?.x, [prefix + '_y']: value?.y };
    const api = {
      get id() { return info.name; }, get windowId() { return info.windowId; },
      getState: (options = {}) => observe('get_app_state', options),
      getAXState: (options = {}) => observe('get_app_state', { ...options, screenshot: false }),
      getWindow: (id) => { if (!Number.isInteger(id)) throw new Error('Use a windowId from getState().windows'); return makeApp(info.name, id, deliveryMode); },
      waitFor: (options) => observe('wait_for', options),
      startRecording: (options = {}) => {
        if (!Number.isInteger(info.windowId)) throw new Error('This app has no observed windowId. Use computer.listRecordingTargets() to choose a capturable window.');
        return startRecording({ ...options, window_id: info.windowId });
      },
      click: (value, options = {}) => invoke('click', { ...target(value), ...options }),
      drag: (from, to, options = {}) => invoke('drag', { ...endpoint('from', from), ...endpoint('to', to), ...options }),
      pressKey: (key, options = {}) => invoke('press_key', { ...(Array.isArray(key) ? { keys: key } : { key }), ...options }, false),
      typeText: (text, options = {}) => invoke('type_text', { text, ...options }),
      pasteText: (text, options = {}) => invoke('paste_text', { text, delivery_mode: 'foreground', ...options }),
      setValue: (element, value, options = {}) => invoke('set_value', { element_index: element, value, ...options }),
      selectText: (element, text, options = {}) => invoke('select_text', { element_index: element, text, ...options }),
      performSecondaryAction: (element, action, options = {}) => invoke('perform_secondary_action', { element_index: element, action, ...options }),
      scroll: (direction, options = {}) => invoke('scroll', { direction, ...options }),
      toJSON: () => ({ app: info.name, windowId: info.windowId })
    };
    return api;
  };
  globalThis.computer = Object.freeze({
    write,
    listApps: () => call('list_apps'),
    listRecordingTargets: () => call('list_recording_targets'),
    startRecording,
    recordingStatus: (id) => call('recording_status', id === undefined ? {} : { recording_id: id }),
    stopRecording: (id) => call('stop_recording', { recording_id: id }),
    getApp: async (name, options = {}) => {
      if (typeof name !== 'string' || !name.trim()) throw new Error('getApp requires an app name, path or bundle ID');
      const key = JSON.stringify([name, options.window_id, options.delivery_mode]);
      let app = handles.get(key);
      if (!app) { app = makeApp(name, options.window_id, options.delivery_mode); handles.set(key, app); }
      const { emit, delivery_mode, window_id, ...observation } = options;
      const state = await app.getState(observation);
      if (options.emit !== false) write(state);
      return app;
    }
  });
}
`

export const buildComputerUseReplSource = (code: string): string => `
(async () => {
  "use strict";
  globalThis.__codevisor_outputs = [];
  ${API_SOURCE}
  ${computerUseCellBody(code)}
})()
`
