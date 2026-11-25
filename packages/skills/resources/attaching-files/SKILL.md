---
name: attaching-files
description: Use when the user should see or receive a file in Codevisor, such as a screenshot, screen recording, generated image, PDF, report, or export, including requests like "change this and send me a video" or "take a screenshot of my desktop".
---

# Attach files

A file reaches the user only when your reply links to it. Creating, saving, or inspecting a file sends nothing.

## Quick reference

| To                                     | Write                                                          |
| -------------------------------------- | -------------------------------------------------------------- |
| Embed an image, video, or PDF          | `![Screenshot](./output/screenshot.png)` on its own line       |
| Mention a file in passing              | `You can see the bug in [index.tsx](./src/index.tsx) where...` |
| Link a path with spaces or parentheses | `![Screenshot](</tmp/screen shot (1).png>)`                    |

- Embed files that you want the user to look at by default. i.e. before/after images, you generated an image, screenshot of a feature, a video of a change, etc. These should all be embedded in your response by default, instead of sent as links, unless the user says otherwise.
- Use a plain link for things like giving a source when referencing something. As a general rule of thumb if you are showing something to the user embed the file... if you are telling the user about a file (like referencing a source from the repo) link to the file.
- Link a file that exists on the machine running the session. Relative paths resolve from the session's working directory; absolute paths also work.

## Common mistakes

- Putting the embed or link inside code formatting. Write it as plain Markdown in your reply.
- Saying "I recorded a demo" with no embed. The user receives nothing until the reply links the file.
- Repeating an image from Codex's built-in image generation. Codevisor already shows it.
- Sending a reference to an image or video as a link rather than embedding it in the response.
