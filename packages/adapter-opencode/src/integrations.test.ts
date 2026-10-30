import { expect, it } from "vitest"

import {
  openCodeFormAnswer,
  openCodeProvidersFromIntegrations,
  type OpenCodeIntegration
} from "./integrations.js"

const integrations: ReadonlyArray<OpenCodeIntegration> = [
  {
    id: "openai",
    name: "OpenAI",
    methods: [
      { type: "key" },
      { type: "env" },
      { id: "chatgpt-token-sharing", type: "oauth", label: "Sign in with ChatGPT" },
      { id: "chatgpt-browser", type: "oauth", label: "Codex browser (legacy)" }
    ],
    connections: [{ type: "credential", method: "oauth" }]
  },
  {
    id: "github-copilot",
    name: "GitHub Copilot",
    methods: [
      { type: "env" },
      {
        id: "device",
        type: "oauth",
        label: "Login with GitHub Copilot",
        form: [
          {
            key: "deploymentType",
            title: "Select GitHub deployment type",
            required: true,
            type: "string",
            options: [
              { value: "github.com", label: "GitHub.com", description: "Public" },
              { value: "enterprise", label: "GitHub Enterprise" }
            ]
          },
          {
            key: "enterpriseUrl",
            title: "Enter your GitHub Enterprise URL or domain",
            required: true,
            type: "string",
            placeholder: "company.ghe.com",
            when: [{ key: "deploymentType", op: "eq", value: "enterprise" }]
          }
        ]
      }
    ],
    connections: []
  },
  {
    id: "opencode",
    name: "OpenCode Console",
    methods: [
      { type: "key", label: "API key (service account)" },
      {
        id: "device",
        type: "oauth",
        label: "OpenCode Console account",
        form: [
          {
            key: "server",
            hidden: true,
            type: "string",
            default: "https://opencode.ai/console"
          }
        ]
      }
    ],
    connections: [{ type: "credential", method: "key" }]
  },
  {
    id: "gitlab",
    name: "GitLab Duo",
    methods: [
      {
        id: "pkce",
        type: "oauth",
        label: "Login with GitLab (OAuth)",
        form: [
          {
            key: "instanceUrl",
            title: "GitLab instance URL",
            type: "string",
            placeholder: "https://gitlab.com",
            default: "https://gitlab.com"
          },
          { key: "selfManaged", title: "Self-managed", type: "boolean", default: false },
          {
            key: "port",
            title: "Port",
            type: "integer",
            when: [{ key: "selfManaged", op: "eq", value: true }]
          },
          { key: "docs", type: "external" }
        ]
      }
    ],
    connections: []
  },
  { id: "env-only", name: "Env Only", methods: [{ type: "env" }], connections: [] }
]

it("presents OpenCode 2 integrations as sign-in providers, keeping OpenCode's method ids", () => {
  expect(openCodeProvidersFromIntegrations(integrations)).toEqual([
    {
      id: "github-copilot",
      name: "GitHub Copilot",
      methods: [
        {
          id: "device",
          type: "oauth",
          label: "Login with GitHub Copilot",
          prompts: [
            {
              type: "select",
              key: "deploymentType",
              message: "Select GitHub deployment type",
              options: [
                { value: "github.com", label: "GitHub.com", hint: "Public" },
                { value: "enterprise", label: "GitHub Enterprise" }
              ],
              required: true
            },
            {
              type: "text",
              key: "enterpriseUrl",
              message: "Enter your GitHub Enterprise URL or domain",
              placeholder: "company.ghe.com",
              options: [],
              required: true,
              when: { key: "deploymentType", op: "eq", value: "enterprise" }
            }
          ]
        }
      ]
    },
    {
      id: "gitlab",
      name: "GitLab Duo",
      methods: [
        {
          id: "pkce",
          type: "oauth",
          label: "Login with GitLab (OAuth)",
          prompts: [
            {
              type: "text",
              key: "instanceUrl",
              message: "GitLab instance URL",
              placeholder: "https://gitlab.com",
              options: [],
              required: false,
              defaultValue: "https://gitlab.com"
            },
            {
              type: "select",
              key: "selfManaged",
              message: "Self-managed",
              options: [
                { value: "true", label: "Yes" },
                { value: "false", label: "No" }
              ],
              required: false,
              defaultValue: "false"
            },
            {
              type: "text",
              key: "port",
              message: "Port",
              options: [],
              required: false,
              when: { key: "selfManaged", op: "eq", value: "true" }
            }
          ]
        }
      ]
    },
    {
      id: "openai",
      name: "OpenAI",
      methods: [
        { id: "key", type: "api", label: "API Key", prompts: [] },
        { id: "chatgpt-token-sharing", type: "oauth", label: "Sign in with ChatGPT", prompts: [] },
        { id: "chatgpt-browser", type: "oauth", label: "Codex browser (legacy)", prompts: [] }
      ],
      credentialType: "oauth"
    },
    {
      id: "opencode",
      name: "OpenCode Console",
      methods: [
        { id: "key", type: "api", label: "API key (service account)", prompts: [] },
        { id: "device", type: "oauth", label: "OpenCode Console account", prompts: [] }
      ],
      credentialType: "api"
    }
  ])
})

it("answers OpenCode's form in its own field types, leaving blank answers to OpenCode's defaults", () => {
  expect(
    openCodeFormAnswer(integrations, "gitlab", "pkce", {
      instanceUrl: " ",
      selfManaged: "true",
      port: "8443",
      extra: " kept "
    })
  ).toEqual({ selfManaged: true, port: 8443, extra: "kept" })
  expect(openCodeFormAnswer(integrations, "opencode", "device", { server: "" })).toBeUndefined()
  expect(openCodeFormAnswer(integrations, "opencode", "key", { label: "ci" })).toEqual({
    label: "ci"
  })
  expect(openCodeFormAnswer([], "missing", "device", { flag: "true" })).toEqual({ flag: "true" })
})

it("offers Claude Agent's Claude Code login as an account sign-in, and labels external logins", () => {
  expect(
    openCodeProvidersFromIntegrations([
      {
        id: "claude-agent",
        name: "Claude Agent",
        methods: [{ id: "claude-login", type: "external", label: "Claude Code login" }],
        connections: []
      },
      {
        id: "amazon-bedrock",
        name: "Amazon Bedrock",
        methods: [{ id: "aws-profile", type: "external", label: "AWS profile" }],
        connections: [{ type: "credential", method: "external" }]
      }
    ])
  ).toEqual([
    { id: "amazon-bedrock", name: "Amazon Bedrock", methods: [], credentialType: "wellknown" },
    {
      id: "claude-agent",
      name: "Claude Agent",
      methods: [
        { id: "claude-login", type: "oauth", label: "Claude account in Codevisor", prompts: [] }
      ]
    }
  ])
})
