---
name: attaching-files
description: Send or show files to the user in Codevisor. Use when asked for a screenshot, screen recording, generated image, report, or other file, including requests such as "change this and send me a video" or "take a screenshot of my desktop".
---

# Attach files

Include a Markdown link in your response to let the user open a file: `[View recording](./output/demo.mp4)`.

Use an embed for an inline preview: `![Recording](./output/demo.mp4)`. Codevisor previews images, videos, and PDFs; other files appear as file attachments.

Use an existing file on the machine running the session. Relative paths resolve from the session's working directory; absolute paths also work. Wrap paths containing spaces or parentheses in angle brackets: `![Screenshot](</tmp/screen shot.png>)`.

Place the actual link or embed in your response, outside code formatting. Creating or inspecting a file does not send it to the user. Codex's built-in image generation is displayed automatically by Codevisor; you do not need to repeat that image in Markdown.
