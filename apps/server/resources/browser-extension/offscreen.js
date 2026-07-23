const blobBase64 = async (blob) => {
  const bytes = new Uint8Array(await blob.arrayBuffer())
  let binary = ""
  for (let index = 0; index < bytes.length; index += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(index, index + 0x8000))
  }
  return btoa(binary)
}

const clipboardEntry = (entry) => {
  if (typeof entry.text === "string") {
    return new Blob([entry.text], { type: entry.mimeType })
  }
  const binary = atob(entry.base64 ?? "")
  const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0))
  return new Blob([bytes], { type: entry.mimeType })
}

const runClipboardEvent = (type, populate) =>
  new Promise((resolve, reject) => {
    let dispatched = false
    const listener = (event) => {
      dispatched = true
      event.preventDefault()
      Promise.resolve(populate(event.clipboardData)).then(resolve, reject)
    }
    document.addEventListener(type, listener, { once: true })
    try {
      if (!document.execCommand(type) || !dispatched) {
        document.removeEventListener(type, listener)
        reject(new Error(`Chrome did not allow the clipboard ${type} operation`))
      }
    } catch (error) {
      document.removeEventListener(type, listener)
      reject(error)
    }
  })

const readText = () =>
  runClipboardEvent("paste", (clipboardData) => ({
    text: clipboardData?.getData("text/plain") ?? ""
  }))

const writeEntries = async (entries) => {
  const prepared = await Promise.all(
    entries.map(async (entry) => {
      const blob = clipboardEntry(entry)
      return entry.mimeType.startsWith("text/")
        ? { mimeType: entry.mimeType, text: await blob.text() }
        : { mimeType: entry.mimeType, blob }
    })
  )
  return runClipboardEvent("copy", (clipboardData) => {
    if (!clipboardData) throw new Error("Chrome did not provide clipboard data")
    for (const entry of prepared) {
      if ("text" in entry) {
        clipboardData.setData(entry.mimeType, entry.text)
        continue
      }
      clipboardData.items.add(
        new File([entry.blob], `codevisor-clipboard.${entry.mimeType.split("/").at(-1) || "bin"}`, {
          type: entry.mimeType
        })
      )
    }
    return { written: true }
  })
}

const readEntries = () =>
  runClipboardEvent("paste", async (clipboardData) => {
    if (!clipboardData) return { items: [] }
    const entries = await Promise.all(
      [...clipboardData.items].map(
        (item) =>
          new Promise((resolve) => {
            if (item.kind === "string") {
              item.getAsString((text) => resolve({ mimeType: item.type || "text/plain", text }))
              return
            }
            const blob = item.getAsFile()
            if (!blob) {
              resolve(undefined)
              return
            }
            void blobBase64(blob).then((base64) =>
              resolve({ mimeType: item.type || blob.type, base64 })
            )
          })
      )
    )
    const presentEntries = entries.filter(Boolean)
    return { items: presentEntries.length === 0 ? [] : [{ entries: presentEntries }] }
  })

const perform = async (method, params) => {
  switch (method) {
    case "readText":
      return readText()
    case "writeText":
      return writeEntries([{ mimeType: "text/plain", text: String(params.text ?? "") }])
    case "read":
      return readEntries()
    case "write": {
      const entries = (params.items ?? []).flatMap((item) => item.entries ?? [])
      return writeEntries(entries)
    }
    default:
      throw new Error(`Unsupported clipboard operation: ${method}`)
  }
}

chrome.runtime.onMessage.addListener((message) => {
  if (message?.target !== "codevisor-offscreen") return false
  return perform(message.method, message.params ?? {}).then(
    (result) => ({ ok: true, result }),
    (error) => ({ ok: false, error: error instanceof Error ? error.message : String(error) })
  )
})
