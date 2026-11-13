import {
  conversationsReply,
  fileSearchReply,
  membersReply,
  messageSearchReply,
  messagesReply,
  pageCursor,
  type SlackConversation,
  type SlackUser,
  userReply
} from "./slack-api-schemas.js"
import { conversationType, displayNameOf, type SlackDirectory } from "./slack-directory.js"
import { botUsersIn, messageSummary, peopleIn } from "./slack-messages.js"
import {
  channelTypes,
  fileSearchArguments,
  findUsersArguments,
  getUserArguments,
  listChannelsArguments,
  membersArguments,
  readChannelArguments,
  readThreadArguments,
  searchArguments
} from "./slack-tool-arguments.js"
import type { ToolRunner } from "./slack-tool-runner.js"

export const maxFoundUsers = 20

export const searchMessages: ToolRunner = async (args, { api, directory }) => {
  const { query, sort, count, page } = searchArguments.parse(args)
  const found = messageSearchReply.parse(
    await api.call("search.messages", { query, count, page, ...searchOrder(sort) })
  ).messages
  const bots = await botUsersIn(found.matches, directory)
  const people = await directory.people([
    ...peopleIn(found.matches),
    ...found.matches.flatMap((match) => dmPartnerOf(match.channel) ?? [])
  ])
  return {
    messages: found.matches.map((match) => ({
      channel: searchChannel(match.channel, people),
      ...messageSummary(match, bots),
      ...(match.permalink === undefined ? {} : { link: match.permalink })
    })),
    people,
    ...pagination(found.pagination)
  }
}

export const searchFiles: ToolRunner = async (args, { api }) => {
  const { query, count, page } = fileSearchArguments.parse(args)
  const found = fileSearchReply.parse(await api.call("search.files", { query, count, page })).files
  return {
    files: found.matches.map((file) => ({
      id: file.id,
      name: file.title ?? file.name ?? file.id,
      ...(file.filetype === undefined ? {} : { type: file.filetype }),
      ...(file.user === undefined ? {} : { sharedBy: file.user }),
      ...(file.permalink === undefined ? {} : { link: file.permalink })
    })),
    ...pagination(found.pagination)
  }
}

export const listChannels: ToolRunner = async (args, { api, directory }) => {
  const { query, types, limit, cursor } = listChannelsArguments.parse(args)
  const body = await api.call("users.conversations", {
    types: types.map((type) => channelTypes[type]).join(","),
    exclude_archived: true,
    limit,
    cursor
  })
  const channels = await Promise.all(
    conversationsReply.parse(body).channels.map((channel) => channelSummary(channel, directory))
  )
  return { channels: channels.filter((channel) => named(channel, query)), ...nextCursor(body) }
}

export const findUsers: ToolRunner = async (args, { api, directory }) => {
  const { query } = findUsersArguments.parse(args)
  if (query.includes("@") && !query.startsWith("@")) {
    const found = await api.call("users.lookupByEmail", { email: query }).then(
      (body) => [userReply.parse(body).user],
      () => []
    )
    return { users: found.map(userSummary) }
  }

  const wanted = query.replace(/^@/, "").toLowerCase()
  const matches = (await directory.allUsers()).filter(
    (user) => !user.deleted && matchesName(user, wanted)
  )
  return { users: matches.slice(0, maxFoundUsers).map(userSummary) }
}

export const getUser: ToolRunner = async (args, { directory }) => {
  const { user } = getUserArguments.parse(args)
  const profile = await directory.user(await directory.userIdFor(user))
  if (profile === null) return { found: false }

  return {
    ...userSummary(profile),
    ...(profile.profile?.email ? { email: profile.profile.email } : {}),
    ...(profile.tz === undefined ? {} : { timeZone: profile.tz })
  }
}

export const readChannel: ToolRunner = async (args, { api, directory }) => {
  const { channel, limit, oldest, latest, cursor } = readChannelArguments.parse(args)
  const id = await directory.resolveConversation(channel)
  const body = await api.call("conversations.history", {
    channel: id,
    limit,
    oldest,
    latest,
    cursor
  })
  const messages = messagesReply.parse(body).messages.toReversed()
  const bots = await botUsersIn(messages, directory)
  return {
    channel: id,
    messages: messages.map((message) => messageSummary(message, bots)),
    people: await directory.people(peopleIn(messages)),
    ...nextCursor(body)
  }
}

export const readThread: ToolRunner = async (args, { api, directory }) => {
  const { channel, ts, limit, cursor } = readThreadArguments.parse(args)
  const id = await directory.resolveConversation(channel)
  const body = await api.call("conversations.replies", { channel: id, ts, limit, cursor })
  const messages = messagesReply.parse(body).messages
  const bots = await botUsersIn(messages, directory)
  return {
    channel: id,
    messages: messages.map((message) => messageSummary(message, bots)),
    people: await directory.people(peopleIn(messages)),
    ...nextCursor(body)
  }
}

export const listChannelMembers: ToolRunner = async (args, { api, directory }) => {
  const { channel, limit, cursor } = membersArguments.parse(args)
  const id = await directory.resolveConversation(channel)
  const body = await api.call("conversations.members", { channel: id, limit, cursor })
  const members = membersReply.parse(body).members
  const people = await directory.people(members)
  return {
    channel: id,
    members: members.map((member) => ({ id: member, name: people[member] ?? member })),
    ...nextCursor(body)
  }
}

interface SearchChannel {
  id: string
  name?: string | undefined
}

const dmPartnerOf = (channel: SearchChannel): string | undefined =>
  channel.id.startsWith("D") && channel.name !== undefined && userIdPattern.test(channel.name)
    ? channel.name
    : undefined

const userIdPattern = /^[UW][A-Z0-9]+$/

const searchChannel = (channel: SearchChannel, people: Readonly<Record<string, string>>) => {
  const partner = dmPartnerOf(channel)
  const name = partner === undefined ? channel.name : (people[partner] ?? partner)
  return { id: channel.id, ...(name ? { name } : {}) }
}

const searchOrder = (sort: "newest" | "relevance") =>
  sort === "newest" ? { sort: "timestamp", sort_dir: "desc" } : { sort: "score" }

interface SearchPaging {
  page: number
  page_count: number
  total_count: number
}

const pagination = (paging: SearchPaging | undefined) => {
  if (paging === undefined) return {}

  return { page: paging.page, pages: paging.page_count, total: paging.total_count }
}

const nextCursor = (body: Record<string, unknown>): { nextCursor?: string } => {
  const cursor = pageCursor.parse(body)
  return cursor === undefined ? {} : { nextCursor: cursor }
}

interface ChannelSummary {
  id: string
  name: string
  type: string
  topic?: string
}

const channelSummary = async (
  channel: SlackConversation,
  directory: SlackDirectory
): Promise<ChannelSummary> => ({
  id: channel.id,
  name: (await directory.nameOf(channel)) ?? channel.id,
  type: conversationType(channel),
  ...(channel.topic?.value ? { topic: channel.topic.value } : {})
})

const named = (channel: ChannelSummary, query: string | undefined): boolean =>
  query === undefined ||
  query === "" ||
  channel.name.toLowerCase().includes(query.replace(/^#/, "").toLowerCase())

const matchesName = (user: SlackUser, wanted: string): boolean =>
  [user.name, user.real_name, user.profile?.display_name, user.profile?.real_name].some((name) =>
    name?.toLowerCase().includes(wanted)
  )

const userSummary = (user: SlackUser): Record<string, unknown> => ({
  id: user.id,
  name: displayNameOf(user),
  handle: user.name,
  ...(user.profile?.title ? { title: user.profile.title } : {}),
  ...(user.is_bot === true ? { bot: true } : {})
})
