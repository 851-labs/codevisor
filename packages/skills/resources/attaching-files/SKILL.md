---
name: attaching-files
description: Send or show files to the user in Codevisor. Use when asked for a screenshot, screen recording, generated image, report, or other file, including requests such as "change this and send me a video" or "take a screenshot of my desktop".
---

# Attach files

Default to Markdown embeds when showing images, videos, or PDFs: `![Screenshot](./output/screenshot.png)` or `![View recording](./output/demo.mp4)`. Use embeds to show your work, demonstrate a result, or show how something looks so the user can see it directly in chat without opening a link. Place each embed on its own line.

Use a plain Markdown link for an incidental reference within a sentence, such as `The [original screenshot](./output/before.png) shows the previous layout.`, or for files intended only to be opened or downloaded. Also use a plain link when the user explicitly asks for one.

Codevisor previews embedded images, videos, and PDFs; other files appear as file attachments.

Use an existing file on the machine running the session. Relative paths resolve from the session's working directory; absolute paths also work. Wrap paths containing spaces or parentheses in angle brackets: `![Screenshot](</tmp/screen shot.png>)`.

Place the actual link or embed in your response, outside code formatting. Creating or inspecting a file does not send it to the user. Codex's built-in image generation is displayed automatically by Codevisor; you do not need to repeat that image in Markdown.
