/// Chrome tab groups for the Codevisor relay extension. Loaded into the
/// service worker with importScripts, so everything here is a plain global.
/// CDP has no tab-group surface; these commands wrap chrome.tabs.group and
/// chrome.tabGroups for the server's tab_groups tool.

const TAB_GROUP_NONE = -1

const TAB_GROUP_COLORS = new Set([
  "grey",
  "blue",
  "red",
  "yellow",
  "green",
  "pink",
  "purple",
  "cyan",
  "orange"
])

const describeTabGroup = async (groupId) => {
  const group = await chrome.tabGroups.get(groupId)
  const tabs = await chrome.tabs.query({ groupId })
  return {
    id: group.id,
    title: group.title ?? "",
    color: group.color,
    collapsed: group.collapsed === true,
    windowId: group.windowId,
    tabIds: tabs.map((tab) => String(tab.id))
  }
}

const tabGroupUpdateProperties = (params) => {
  const properties = {}
  if (typeof params?.title === "string") properties.title = params.title
  if (params?.color !== undefined) {
    if (!TAB_GROUP_COLORS.has(params.color))
      throw new Error(`Unsupported tab group color: ${params.color}`)
    properties.color = params.color
  }
  if (typeof params?.collapsed === "boolean") properties.collapsed = params.collapsed
  return properties
}

/// Only tabs Codevisor has been shown may be regrouped, mirroring closeTarget.
const groupableTabIds = (allowedTabs, raw) => {
  if (!Array.isArray(raw) || raw.length === 0) throw new Error("tabIds must be a non-empty array")
  return raw.map((value) => {
    const tabId = Number(value)
    if (!Number.isInteger(tabId) || !allowedTabs.has(tabId)) {
      throw new Error(`That tab is not shared with Codevisor: ${value}`)
    }
    return tabId
  })
}

const knownGroupId = (raw) => {
  const groupId = Number(raw)
  if (!Number.isInteger(groupId) || groupId === TAB_GROUP_NONE) {
    throw new Error("groupId must identify an existing tab group")
  }
  return groupId
}

// Consumed by background.js after importScripts, so it is published explicitly.
globalThis.handleTabGroupCommand = async (allowedTabs, message) => {
  switch (message.method) {
    case "Codevisor.tabGroups.list": {
      const groups = await chrome.tabGroups.query({})
      return { groups: await Promise.all(groups.map((group) => describeTabGroup(group.id))) }
    }
    case "Codevisor.tabGroups.create": {
      const tabIds = groupableTabIds(allowedTabs, message.params?.tabIds)
      const groupId = await chrome.tabs.group({ tabIds })
      const properties = tabGroupUpdateProperties(message.params)
      if (Object.keys(properties).length > 0) await chrome.tabGroups.update(groupId, properties)
      return { group: await describeTabGroup(groupId) }
    }
    case "Codevisor.tabGroups.update": {
      const groupId = knownGroupId(message.params?.groupId)
      const properties = tabGroupUpdateProperties(message.params)
      if (Object.keys(properties).length > 0) await chrome.tabGroups.update(groupId, properties)
      return { group: await describeTabGroup(groupId) }
    }
    case "Codevisor.tabGroups.add": {
      const groupId = knownGroupId(message.params?.groupId)
      const tabIds = groupableTabIds(allowedTabs, message.params?.tabIds)
      await chrome.tabs.group({ groupId, tabIds })
      return { group: await describeTabGroup(groupId) }
    }
    case "Codevisor.tabGroups.ungroup": {
      await chrome.tabs.ungroup(groupableTabIds(allowedTabs, message.params?.tabIds))
      return {}
    }
    default:
      throw new Error(`Unsupported tab group command: ${message.method}`)
  }
}
