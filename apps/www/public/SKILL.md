---
name: codevisor
description: Install Codevisor on your computer and delegate coding work to agents (Claude Code, Codex, and others) through it. Use when the user asks you to set up Codevisor or have its agents work on their projects.
---

# Codevisor

## Install

Skip this if `codevisor status` shows a running server.

```bash
curl -fsSL https://www.codevisor.dev/install.sh | sh
```

In a root shell, the server runs as a `codevisor` account; run later commands as that account
(`su - codevisor -c '…'`).

## Connect to the user's account

Run `codevisor auth login --name "<machine name>"` in the background. Send the user the link it
prints and wait for `✓ Connected`. Don't use `codevisor setup`: it needs an interactive terminal.

## Connect the gateway

Add a local stdio MCP server that runs `codevisor mcp`, for example
`grok mcp add codevisor -- codevisor mcp`. Then call its `skills` tool with `execute`, then
`codevisor-agents`, and follow them. Don't install a separate Codevisor skill.

Codevisor installs coding harnesses and shares the user's sign-ins on its own. Don't install them
or ask for API keys.

## Start working

Don't stop after setup. If the user already asked for something, start an agent on it; otherwise
ask what to work on. Setup is complete only when an agent you started replies.
