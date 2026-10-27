export type ScalarKind = "string" | "int" | "double" | "bool" | "dyn"

export type FieldShape =
  | { readonly kind: ScalarKind; readonly nullable: boolean }
  | { readonly kind: "list"; readonly items: FieldShape; readonly nullable: boolean }
  | { readonly kind: "map"; readonly values: FieldShape; readonly nullable: boolean }
  | {
      readonly kind: "record"
      readonly fields: ReadonlyMap<string, FieldShape>
      readonly nullable: boolean
    }

export type RecordShape = Extract<FieldShape, { kind: "record" }>

export const dynShape: FieldShape = { kind: "dyn", nullable: false }

export const shapeOfSchema = (schema: unknown): FieldShape => shapeAtDepth(schema, 0)

export const isCelIdentifier = (name: string): boolean =>
  identifierPattern.test(name) && !reservedWords.has(name)

export const isObject = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value)

const maxSchemaDepth = 8

const identifierPattern = /^[A-Za-z_][A-Za-z0-9_]*$/

const reservedWords = new Set([
  "as",
  "break",
  "const",
  "continue",
  "else",
  "false",
  "for",
  "function",
  "if",
  "import",
  "in",
  "let",
  "loop",
  "namespace",
  "null",
  "package",
  "return",
  "true",
  "var",
  "void",
  "while"
])

const scalarKinds: Readonly<Record<string, ScalarKind>> = {
  boolean: "bool",
  integer: "int",
  number: "double",
  string: "string"
}

const shapeAtDepth = (schema: unknown, depth: number): FieldShape => {
  if (!isObject(schema) || depth > maxSchemaDepth) return dynShape

  const declared = declaredType(schema.type)
  const shape = shapeOfType(schema, declared.type, depth)
  return { ...shape, nullable: declared.nullable }
}

interface DeclaredType {
  readonly type: string | undefined
  readonly nullable: boolean
}

const declaredType = (type: unknown): DeclaredType => {
  if (typeof type === "string") return { type, nullable: false }
  if (!Array.isArray(type)) return { type: undefined, nullable: false }

  const concrete = type.filter((entry) => entry !== "null")
  const single = concrete.length === 1 && typeof concrete[0] === "string" ? concrete[0] : "dyn"
  return { type: single, nullable: concrete.length < type.length }
}

const shapeOfType = (
  schema: Record<string, unknown>,
  type: string | undefined,
  depth: number
): FieldShape => {
  if (type === "array")
    return { kind: "list", items: shapeAtDepth(schema.items, depth + 1), nullable: false }
  if (type === "object" || (type === undefined && "properties" in schema))
    return objectShape(schema, depth)

  return { kind: scalarKinds[type ?? ""] ?? "dyn", nullable: false }
}

const objectShape = (schema: Record<string, unknown>, depth: number): FieldShape => {
  const fields = propertyShapes(schema.properties, depth)
  if (fields.size > 0) return { kind: "record", fields, nullable: false }

  return {
    kind: "map",
    values: shapeAtDepth(schema.additionalProperties, depth + 1),
    nullable: false
  }
}

const propertyShapes = (properties: unknown, depth: number): ReadonlyMap<string, FieldShape> => {
  if (!isObject(properties)) return new Map()

  const named = Object.entries(properties).filter(([name]) => isCelIdentifier(name))
  return new Map(named.map(([name, schema]) => [name, shapeAtDepth(schema, depth + 1)]))
}
