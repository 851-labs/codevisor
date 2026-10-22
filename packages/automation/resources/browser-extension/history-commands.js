const DEFAULT_HISTORY_RESULTS = 100
const MAX_HISTORY_RESULTS = 1000

const historyResultLimit = (maxResults) =>
  typeof maxResults === "number"
    ? Math.max(1, Math.min(MAX_HISTORY_RESULTS, maxResults))
    : DEFAULT_HISTORY_RESULTS

globalThis.searchCodevisorHistory = async (params) => ({
  entries: await chrome.history.search({
    text: params.text ?? "",
    ...(typeof params.startTime === "number" ? { startTime: params.startTime } : {}),
    ...(typeof params.endTime === "number" ? { endTime: params.endTime } : {}),
    maxResults: historyResultLimit(params.maxResults)
  })
})
