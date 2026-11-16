globalThis.CODEVISOR_EXTENSION_PROTOCOL = 1

globalThis.codevisorHello = () => {
  const manifest = chrome.runtime.getManifest()
  return {
    method: "Codevisor.hello",
    params: {
      protocol: globalThis.CODEVISOR_EXTENSION_PROTOCOL,
      version: manifest.version,
      build: manifest.version_name ?? null
    }
  }
}

globalThis.codevisorCommandErrors = () => {
  let last
  return {
    record: (message) => {
      if (message.startsWith("Unsupported browser command")) return
      last = { message, at: Date.now() }
    },
    clear: () => {
      last = undefined
    },
    message: () => last?.message ?? null,
    at: () => last?.at ?? null
  }
}
