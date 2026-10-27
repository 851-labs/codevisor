import type { SkillDefinition } from "@codevisor/plugin-kit"

export const gmailRepliesSkill: SkillDefinition = {
  name: "gmail-replies",
  description:
    "Reply to Gmail messages safely: read the thread, answer in-thread, only to existing participants, draft when unsure.",
  instructions: [
    "# Replying to email with the Gmail plugin",
    "",
    "Email leaves the machine and cannot be unsent. Follow these steps for every reply.",
    "",
    "1. **Read the whole thread first.** Call `read_thread` with the message's `threadId`. Do not reply from a snippet or an event payload alone; later messages may have answered or changed the question.",
    "2. **Reply in the thread.** Pass `inReplyToMessageId` (the Gmail id of the newest message you are answering). The plugin sets `In-Reply-To`, `References`, the thread and a `Re:` subject for you. Do not invent a new subject.",
    "3. **Only write to people already on the thread.** Recipients must come from the thread's From, To and Cc headers. Never add new addresses unless the user named them, and never reply-all to a mailing list or a large group unless asked.",
    "4. **Draft when unsure.** Use `create_draft` instead of `send` when the user did not explicitly ask you to send, when the message commits them to anything (money, dates, legal or HR matters), when recipients are unclear, or when the thread is sensitive. Tell the user a draft is waiting.",
    "5. **Keep it short and plain.** Plain text, the user's voice, no signatures unless the thread already uses one.",
    "",
    'After sending, mark the original read with `modify_labels` (`remove: ["UNREAD"]`) only if the user wants that.',
    ""
  ].join("\n"),
  files: []
}
