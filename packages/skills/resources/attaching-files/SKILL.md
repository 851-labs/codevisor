---
name: attaching-files
description: Use when the user should see or receive a file in Codevisor, such as a screenshot, screen recording, generated image, PDF, report, or export, including requests like "change this and send me a video" or "take a screenshot of my desktop".
---

# Attach files

A file reaches the user only when your reply links to it. Creating, saving, or inspecting a file sends nothing.

## Quick reference

| To                                     | Write                                                                  |
| -------------------------------------- | ---------------------------------------------------------------------- |
| Show an image, video, or PDF           | `![Screenshot](./output/screenshot.png)` on its own line               |
| Mention a file in passing              | `The [original screenshot](./output/before.png) shows the old layout.` |
| Offer a file to open or download       | `[Download the report](./output/report.csv)`                           |
| Link a path with spaces or parentheses | `![Screenshot](</tmp/screen shot (1).png>)`                            |

- Embed by default when you show your work, a result, or how something looks, so the user sees it in the chat without opening a link. Codevisor previews embedded images, videos, and PDFs; other files appear as file attachments.
- Use a plain link for an incidental mention, for a file meant only to be opened or downloaded, or when the user asks for a link.
- Link a file that exists on the machine running the session. Relative paths resolve from the session's working directory; absolute paths also work.

## Common mistakes

- Putting the embed or link inside code formatting. Write it as plain Markdown in your reply.
- Saying "I recorded a demo" with no embed. The user receives nothing until the reply links the file.
- Repeating an image from Codex's built-in image generation. Codevisor already shows it.
