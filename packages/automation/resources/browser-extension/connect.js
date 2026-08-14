const tabsElement = document.querySelector("#tabs")
const statusElement = document.querySelector("#status")

statusElement.textContent = "Checking Codevisor…"
chrome.runtime.sendMessage({ type: "status" }).then((response) => {
  statusElement.textContent = response?.connected
    ? "Connected to Codevisor. You can return to the app."
    : "Waiting for Codevisor. Keep the app running and this extension will reconnect automatically."
  if (response?.connected) {
    chrome.tabs.query({}).then((tabs) => {
      const shareable = tabs.filter(
        (tab) =>
          tab.id !== undefined &&
          tab.id !== chrome.tabs.TAB_ID_NONE &&
          typeof tab.url === "string" &&
          /^(https?|file):/.test(tab.url)
      )
      if (shareable.length === 0) return
      for (const tab of shareable) {
        const button = document.createElement("div")
        button.className = "tab"
        const title = document.createElement("strong")
        const url = document.createElement("span")
        title.textContent = tab.title || "Untitled tab"
        url.textContent = tab.url
        button.append(title, url)
        tabsElement.append(button)
      }
    })
  }
})
