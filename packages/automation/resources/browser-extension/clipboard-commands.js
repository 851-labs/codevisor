let offscreenCreation

const ensureOffscreenDocument = async () => {
  if (await chrome.offscreen.hasDocument()) return
  offscreenCreation ??= chrome.offscreen
    .createDocument({
      url: "offscreen.html",
      reasons: ["CLIPBOARD"],
      justification: "Read and write the clipboard for Codevisor Browser Use."
    })
    .finally(() => {
      offscreenCreation = undefined
    })
  await offscreenCreation
}

globalThis.runClipboardCommand = async (method, params) => {
  await ensureOffscreenDocument()
  const response = await chrome.runtime.sendMessage({
    target: "codevisor-offscreen",
    method,
    params
  })
  if (response?.ok !== true) {
    throw new Error(response?.error || "The Codevisor clipboard operation failed")
  }
  return response.result ?? {}
}
