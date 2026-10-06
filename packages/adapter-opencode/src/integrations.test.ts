import { expect, it } from "vitest"

import { openCodeProvidersFromIntegrations, type OpenCodeIntegration } from "./integrations.js"

// Captured from OpenCode 2.0.24's GET /api/integration.
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
            type: "string",
            options: [
              { value: "github.com", label: "GitHub.com", description: "Public" },
              { value: "enterprise", label: "GitHub Enterprise" }
            ]
          },
          {
            key: "enterpriseUrl",
            title: "Enter your GitHub Enterprise URL or domain",
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
        form: [{ key: "server", hidden: true, type: "string" }]
      }
    ],
    connections: [{ type: "credential", method: "key" }]
  },
  // Only reachable through an environment variable: nothing to sign in to.
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
              ]
            },
            {
              type: "text",
              key: "enterpriseUrl",
              message: "Enter your GitHub Enterprise URL or domain",
              placeholder: "company.ghe.com",
              options: [],
              when: { key: "deploymentType", op: "eq", value: "enterprise" }
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
