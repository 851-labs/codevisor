import { parseFrontmatter, SkillsError } from "./skills-store.js"

const SKILL_TEMPLATE_BODY = [
  "## Instructions",
  "",
  "Describe the steps the agent should follow when this skill applies."
]

const pastedSkillFile = (
  pasted: string,
  name: string
): { readonly file: string; readonly namingSource: string } => {
  const file = `${pasted}\n`
  let data: Record<string, unknown>
  try {
    data = parseFrontmatter(file).data
  } catch {
    throw new SkillsError("The pasted SKILL.md frontmatter is not valid YAML", "invalid")
  }
  const ownName = typeof data["name"] === "string" && data["name"] !== "" ? data["name"] : name
  return { file, namingSource: ownName }
}

const templateSkillFile = (
  pasted: string,
  name: string,
  description: string
): { readonly file: string; readonly namingSource: string } => {
  const body = pasted !== "" ? pasted : [description, "", ...SKILL_TEMPLATE_BODY].join("\n")
  const file = [
    "---",
    `name: ${JSON.stringify(name)}`,
    `description: ${JSON.stringify(description)}`,
    "---",
    "",
    body,
    ""
  ].join("\n")
  return { file, namingSource: name }
}

export const newSkillFile = (request: {
  readonly name: string
  readonly description: string
  readonly content?: string | undefined
}): { readonly file: string; readonly namingSource: string } => {
  const name = request.name.trim()
  if (name === "") throw new SkillsError("Skill name is required", "invalid")
  const description = request.description.trim() || name
  const pasted = request.content?.trim() ?? ""
  if (pasted.startsWith("---")) return pastedSkillFile(pasted, name)
  return templateSkillFile(pasted, name, description)
}

export const validateSkillFile = (content: string): void => {
  let data: Record<string, unknown>
  try {
    data = parseFrontmatter(content).data
  } catch {
    throw new SkillsError("The SKILL.md frontmatter is not valid YAML", "invalid")
  }
  if (
    typeof data["name"] !== "string" ||
    data["name"].trim() === "" ||
    typeof data["description"] !== "string" ||
    data["description"].trim() === ""
  ) {
    throw new SkillsError("Include a name and description in the SKILL.md frontmatter", "invalid")
  }
}
