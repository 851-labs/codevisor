import {
  conversationReply,
  conversationsReply,
  identityReply,
  pageCursor,
  type SlackConversation,
  type SlackUser,
  userReply,
  usersReply
} from "./slack-api-schemas.js"
import type { SlackApi } from "./slack-api.js"

export interface SlackIdentity {
  userId: string
  user: string
  teamId: string
  team: string
  url: string
}

export interface SlackDirectory {
  me(): Promise<SlackIdentity>
  user(userId: string): Promise<SlackUser | null>
  personName(userId: string): Promise<string | null>
  people(userIds: Iterable<string>): Promise<Record<string, string>>
  conversation(channelId: string): Promise<SlackConversation | null>
  conversationName(channelId: string): Promise<string | null>
  nameOf(conversation: SlackConversation): Promise<string | null>
  memberChannels(): Promise<ReadonlyArray<SlackConversation>>
  allUsers(): Promise<ReadonlyArray<SlackUser>>
  resolveConversation(reference: string): Promise<string>
  userIdFor(reference: string): Promise<string>
}

export class SlackToolError extends Error {}

export const maxDirectoryPages = 10
export const directoryPageSize = 200

export const slackDirectory = (api: SlackApi): SlackDirectory => {
  const users = new Map<string, Promise<SlackUser | null>>()
  const conversations = new Map<string, Promise<SlackConversation | null>>()
  let identity: Promise<SlackIdentity> | undefined

  const directory: SlackDirectory = {
    me: () => {
      identity ??= api.call("auth.test").then(identityOf)
      return identity
    },
    user: (userId) => cached(users, userId, () => lookUpUser(api, userId)),
    personName: async (userId) => displayNameOf(await directory.user(userId)),
    people: async (userIds) => peopleNamed(directory, userIds),
    conversation: (channelId) =>
      cached(conversations, channelId, () => lookUpConversation(api, channelId)),
    conversationName: async (channelId) =>
      nameOf(directory, await directory.conversation(channelId)),
    nameOf: (conversation) => nameOf(directory, conversation),
    memberChannels: () => memberChannels(api),
    allUsers: () => allUsers(api),
    resolveConversation: (reference) => resolveConversation(api, directory, reference),
    userIdFor: (reference) => userIdFor(directory, reference)
  }
  return directory
}

export const displayNameOf = (user: SlackUser | null): string | null => {
  if (user === null) return null

  return user.profile?.display_name || user.profile?.real_name || user.real_name || user.name
}

export const conversationType = (channel: SlackConversation): string => {
  if (channel.is_im === true) return "dm"
  if (channel.is_mpim === true) return "group_dm"
  return channel.is_private === true ? "private" : "public"
}

export const slackIdPattern = /^[CGDUW][A-Z0-9]{8,}$/

const cached = <T>(
  cache: Map<string, Promise<T>>,
  key: string,
  load: () => Promise<T>
): Promise<T> => {
  const existing = cache.get(key)
  if (existing !== undefined) return existing

  const loading = load()
  cache.set(key, loading)
  return loading
}

const identityOf = (body: Record<string, unknown>): SlackIdentity => {
  const reply = identityReply.parse(body)
  return {
    userId: reply.user_id,
    user: reply.user,
    teamId: reply.team_id,
    team: reply.team,
    url: reply.url
  }
}

const lookUpUser = (api: SlackApi, userId: string): Promise<SlackUser | null> =>
  api.call("users.info", { user: userId }).then(
    (body) => userReply.parse(body).user,
    () => null
  )

const lookUpConversation = (api: SlackApi, channelId: string): Promise<SlackConversation | null> =>
  api.call("conversations.info", { channel: channelId }).then(
    (body) => conversationReply.parse(body).channel,
    () => null
  )

const peopleNamed = async (
  directory: SlackDirectory,
  userIds: Iterable<string>
): Promise<Record<string, string>> => {
  const unique = [...new Set(userIds)]
  const names = await Promise.all(unique.map((id) => directory.personName(id)))
  return Object.fromEntries(
    unique.flatMap((id, index) => (names[index] ? [[id, names[index]]] : []))
  )
}

const nameOf = async (
  directory: SlackDirectory,
  conversation: SlackConversation | null
): Promise<string | null> => {
  if (conversation === null) return null
  if (conversation.is_im === true && conversation.user !== undefined)
    return directory.personName(conversation.user)

  return conversation.name ?? null
}

const memberChannels = async (api: SlackApi): Promise<ReadonlyArray<SlackConversation>> =>
  pages(api, "users.conversations", conversationsPage, {
    types: "public_channel,private_channel",
    exclude_archived: true
  })

const allUsers = async (api: SlackApi): Promise<ReadonlyArray<SlackUser>> =>
  pages(api, "users.list", usersPage, {})

const conversationsPage = (body: Record<string, unknown>) => conversationsReply.parse(body).channels

const usersPage = (body: Record<string, unknown>) => usersReply.parse(body).members

const pages = async <T>(
  api: SlackApi,
  method: string,
  itemsOf: (body: Record<string, unknown>) => ReadonlyArray<T>,
  params: Record<string, unknown>
): Promise<ReadonlyArray<T>> => {
  const items: Array<T> = []
  let cursor: string | undefined
  for (let page = 0; page < maxDirectoryPages; page += 1) {
    const body = await api.call(method, { ...params, limit: directoryPageSize, cursor })
    items.push(...itemsOf(body))
    cursor = pageCursor.parse(body)
    if (cursor === undefined) break
  }
  return items
}

const resolveConversation = async (
  api: SlackApi,
  directory: SlackDirectory,
  reference: string
): Promise<string> => {
  const trimmed = reference.trim()
  if (/^[CGD]/.test(trimmed) && slackIdPattern.test(trimmed)) return trimmed
  if (slackIdPattern.test(trimmed)) return openDirectMessage(api, trimmed)
  if (trimmed.startsWith("@")) return openDirectMessage(api, await handleOwner(directory, trimmed))

  return channelNamed(directory, trimmed.replace(/^#/, ""))
}

const userIdFor = async (directory: SlackDirectory, reference: string): Promise<string> => {
  const trimmed = reference.trim()
  if (trimmed.toLowerCase() === "me") return (await directory.me()).userId
  if (/^[UW]/.test(trimmed) && slackIdPattern.test(trimmed)) return trimmed

  return handleOwner(directory, trimmed.startsWith("@") ? trimmed : `@${trimmed}`)
}

const openDirectMessage = async (api: SlackApi, userId: string): Promise<string> =>
  conversationReply.parse(await api.call("conversations.open", { users: userId })).channel.id

const handleOwner = async (directory: SlackDirectory, handle: string): Promise<string> => {
  const wanted = handle.slice(1).toLowerCase()
  const owner = (await directory.allUsers()).find((user) => handlesOf(user).includes(wanted))
  if (owner !== undefined) return owner.id

  throw new SlackToolError(
    `Nobody in this workspace goes by ${handle}. Use find_users to look them up.`
  )
}

const handlesOf = (user: SlackUser): ReadonlyArray<string> =>
  [user.name, user.profile?.display_name].flatMap((name) => (name ? [name.toLowerCase()] : []))

const channelNamed = async (directory: SlackDirectory, name: string): Promise<string> => {
  const wanted = name.toLowerCase()
  const channel = (await directory.memberChannels()).find((candidate) => candidate.name === wanted)
  if (channel !== undefined) return channel.id

  throw new SlackToolError(`You aren't in a channel named #${name}. Use list_channels to find it.`)
}
