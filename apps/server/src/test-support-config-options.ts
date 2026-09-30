import type { SessionConfigOption } from "@codevisor/api"

/// The fake runtime's option list for "session-config" chats: reasoning and
/// speed depend on the model, the way Claude's effort and fast mode do.
export const dependencyConfigOptions = (
  model = "model-default",
  reasoning = "low",
  speed = "standard"
): ReadonlyArray<SessionConfigOption> => [
  {
    category: "model",
    currentValue: model,
    id: "model",
    name: "Model",
    options: [
      { name: "Default model", value: "model-default" },
      { name: "Saved model", value: "model-saved" }
    ]
  },
  {
    category: "thought_level",
    currentValue: reasoning,
    id: "reasoning",
    name: "Reasoning",
    options:
      model === "model-saved"
        ? [
            { name: "Low", value: "low" },
            { name: "High", value: "high" }
          ]
        : [{ name: "Low", value: "low" }]
  },
  {
    category: "speed",
    currentValue: speed,
    id: "speed",
    name: "Speed",
    options:
      model === "model-saved"
        ? [
            { name: "Standard", value: "standard" },
            { name: "Fast", value: "fast" }
          ]
        : [{ name: "Standard", value: "standard" }]
  },
  {
    category: "tone",
    currentValue: "brief",
    id: "tone",
    name: "Tone",
    options: [
      {
        group: "response-style",
        name: "Response style",
        options: [
          { name: "Brief", value: "brief" },
          { name: "Detailed", value: "detailed" }
        ]
      }
    ]
  }
]
