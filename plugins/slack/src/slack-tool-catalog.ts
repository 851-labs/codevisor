import type { Tool } from "@modelcontextprotocol/server"

export const maxSearchResults = 50
export const maxReadMessages = 100
export const maxListedChannels = 200
export const maxListedMembers = 100

const readOnly = { readOnlyHint: true, openWorldHint: false }
const reacts = {
  readOnlyHint: false,
  destructiveHint: false,
  idempotentHint: true,
  openWorldHint: false
}
const posts = { readOnlyHint: false, destructiveHint: false, openWorldHint: true }

const text = (description: string) => ({ type: "string", description })
const count = (maximum: number, fallback: number) => ({
  type: "integer",
  minimum: 1,
  maximum,
  description: `Defaults to ${fallback}.`
})

const channel = text(
  "A conversation: a channel id (C…, G…), a DM id (D…), #channel-name for a channel you're in, a user id (U…) or @handle to DM that person."
)
const messageTs = text("The message's ts, such as 1731350000.123400.")
const cursor = text("nextCursor from a previous call.")
const confirm = {
  type: "boolean",
  description:
    "Set true only after showing the user the exact text and where it goes, and getting their explicit approval to post."
}

type Properties = NonNullable<Tool["inputSchema"]["properties"]>

const object = (properties: Properties, required: Array<string> = []): Tool["inputSchema"] => ({
  type: "object",
  properties,
  ...(required.length === 0 ? {} : { required })
})

export const slackTools: ReadonlyArray<Tool> = [
  {
    name: "search_messages",
    description:
      "Search messages the user can see. Supports Slack search syntax such as in:#eng from:@ana after:2026-11-01 has:link. Returns matches with permalinks, newest first unless sort is relevance.",
    inputSchema: object(
      {
        query: text("Slack search query."),
        sort: { type: "string", enum: ["newest", "relevance"], description: "Defaults to newest." },
        count: count(maxSearchResults, 20),
        page: { type: "integer", minimum: 1, description: "Result page, from 1." }
      },
      ["query"]
    ),
    annotations: readOnly
  },
  {
    name: "search_files",
    description:
      "Search files shared in conversations the user can see. Supports Slack search syntax.",
    inputSchema: object(
      {
        query: text("Slack search query."),
        count: count(maxSearchResults, 20),
        page: { type: "integer", minimum: 1, description: "Result page, from 1." }
      },
      ["query"]
    ),
    annotations: readOnly
  },
  {
    name: "list_channels",
    description:
      "List conversations the user is in: channels, private channels, DMs and group DMs, with ids. Filter by name with query.",
    inputSchema: object({
      query: text("Only conversations whose name contains this text."),
      types: {
        type: "array",
        items: { type: "string", enum: ["public", "private", "dm", "group_dm"] },
        description: "Defaults to public and private channels."
      },
      limit: count(maxListedChannels, 100),
      cursor
    }),
    annotations: readOnly
  },
  {
    name: "find_users",
    description:
      "Find people in the workspace by name, @handle or email. Returns user ids for mentions and DMs.",
    inputSchema: object({ query: text("Name, handle or email address.") }, ["query"]),
    annotations: readOnly
  },
  {
    name: "get_user",
    description:
      "Get a person's profile: name, handle, title, email and time zone. Pass me for the user.",
    inputSchema: object({ user: text("A user id (U…), @handle, or me.") }, ["user"]),
    annotations: readOnly
  },
  {
    name: "read_channel",
    description:
      "Read a conversation's recent messages, oldest first, with each thread's reply count. Use nextCursor for older messages and read_thread for replies.",
    inputSchema: object(
      {
        channel,
        limit: count(maxReadMessages, 30),
        oldest: text("Only messages after this ts or ISO time."),
        latest: text("Only messages before this ts or ISO time."),
        cursor
      },
      ["channel"]
    ),
    annotations: readOnly
  },
  {
    name: "read_thread",
    description: "Read a thread: the parent message and its replies, oldest first.",
    inputSchema: object(
      {
        channel,
        ts: text("ts of the thread's parent message."),
        limit: count(maxReadMessages, 50),
        cursor
      },
      ["channel", "ts"]
    ),
    annotations: readOnly
  },
  {
    name: "list_channel_members",
    description: "List the people in a conversation, with names.",
    inputSchema: object({ channel, limit: count(maxListedMembers, 50), cursor }, ["channel"]),
    annotations: readOnly
  },
  {
    name: "download_file",
    description:
      "Download a file shared in Slack to this machine. Returns its local path, and its text when it's a small text file.",
    inputSchema: object({ file: text("File id (F…), from a message or search_files.") }, ["file"]),
    annotations: readOnly
  },
  {
    name: "add_reaction",
    description: "React to a message with an emoji.",
    inputSchema: object(
      {
        channel,
        ts: messageTs,
        emoji: text("Emoji name without colons, such as eyes or white_check_mark.")
      },
      ["channel", "ts", "emoji"]
    ),
    annotations: reacts
  },
  {
    name: "remove_reaction",
    description: "Remove the user's emoji reaction from a message.",
    inputSchema: object({ channel, ts: messageTs, emoji: text("Emoji name without colons.") }, [
      "channel",
      "ts",
      "emoji"
    ]),
    annotations: reacts
  },
  {
    name: "post_message",
    description:
      "Post a message as the user, or reply in a thread with threadTs. Requires the user's explicit approval: confirm must be true.",
    inputSchema: object(
      {
        channel,
        text: text(
          "Message text in Slack mrkdwn. Mention people with <@U…> and channels with <#C…>."
        ),
        threadTs: text("Reply in this thread: the parent message's ts."),
        broadcast: {
          type: "boolean",
          description: "With threadTs, also send the reply to the channel."
        },
        confirm
      },
      ["channel", "text", "confirm"]
    ),
    annotations: posts
  },
  {
    name: "schedule_message",
    description:
      "Schedule a message to post later as the user. Requires the user's explicit approval: confirm must be true.",
    inputSchema: object(
      {
        channel,
        text: text("Message text in Slack mrkdwn."),
        postAt: text(
          "When to post, as an ISO time with a time zone, such as 2026-11-12T09:00:00-08:00."
        ),
        threadTs: text("Reply in this thread: the parent message's ts."),
        confirm
      },
      ["channel", "text", "postAt", "confirm"]
    ),
    annotations: posts
  },
  {
    name: "upload_file",
    description:
      "Share a file from this machine in a conversation as the user. Requires the user's explicit approval: confirm must be true.",
    inputSchema: object(
      {
        channel,
        path: text("Absolute path of the file on this machine."),
        title: text("Title shown in Slack. Defaults to the file name."),
        comment: text("Message posted with the file."),
        threadTs: text("Share it in this thread: the parent message's ts."),
        confirm
      },
      ["channel", "path", "confirm"]
    ),
    annotations: posts
  }
]
