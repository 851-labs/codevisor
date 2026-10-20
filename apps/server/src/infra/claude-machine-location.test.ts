import { homedir } from "node:os"
import { join } from "node:path"

import { claudeKeychainService } from "@codevisor/harness-manager"
import { describe, expect, it } from "vitest"

import { claudeMachineLocation } from "./claude-machine-location.js"

const dataDir = "/fixture/data"

describe("where this machine's Claude Code login lives", () => {
  it.each<[string, NodeJS.ProcessEnv, ReturnType<typeof claudeMachineLocation>]>([
    [
      "Claude Code's own login on a release build",
      { HOME: "/Users/alice" },
      {
        directory: "/Users/alice/.claude",
        keychainService: "Claude Code-credentials",
        isDefault: true
      }
    ],
    [
      "the account's home directory when the environment has none",
      {},
      {
        directory: join(homedir(), ".claude"),
        keychainService: "Claude Code-credentials",
        isDefault: true
      }
    ],
    [
      "Claude Code's configured directory on a release build",
      { HOME: "/Users/alice", CLAUDE_CONFIG_DIR: "/work/claude" },
      {
        directory: "/work/claude",
        keychainService: claudeKeychainService("/work/claude", false),
        isDefault: true
      }
    ],
    [
      "a throwaway Claude Code config directory on a development server",
      {
        HOME: "/Users/alice",
        CLAUDE_CONFIG_DIR: "/work/claude",
        CODEVISOR_DEV_INSTANCE_ID: "lentil"
      },
      {
        directory: "/fixture/data/claude-machine-login-devtest",
        keychainService: claudeKeychainService("/fixture/data/claude-machine-login-devtest", false),
        isDefault: false
      }
    ],
    [
      "an injected directory, never the real Keychain item",
      { HOME: "/Users/alice", CODEVISOR_CLAUDE_CONFIG_DIR: "/tmp/claude" },
      {
        directory: "/tmp/claude",
        keychainService: claudeKeychainService("/tmp/claude", false),
        isDefault: false
      }
    ],
    [
      "an injected Keychain item",
      {
        HOME: "/Users/alice",
        CODEVISOR_CLAUDE_CONFIG_DIR: "/tmp/claude",
        CODEVISOR_CLAUDE_KEYCHAIN_SERVICE: "Claude Code-credentials-e2e"
      },
      { directory: "/tmp/claude", keychainService: "Claude Code-credentials-e2e", isDefault: false }
    ]
  ])("uses %s", (_case, env, expected) => {
    expect(claudeMachineLocation(env, dataDir)).toEqual(expected)
  })
})
