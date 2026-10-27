import type { Environment, ObjectSchema, RegisterVariableDeclaration } from "@marcbachmann/cel-js"

import { dynShape, isObject, type FieldShape, type RecordShape } from "./event-filter-shape.js"

export interface EventFilterAccount {
  readonly id: string
  readonly label?: string
  readonly identity?: string
}

export interface EventFilterContext {
  readonly eventId: string
  readonly name: string
  readonly timestamp: string
  readonly account?: EventFilterAccount
}

export interface FilterVariables {
  readonly unlistedAreDyn: boolean
  readonly declare: (env: Environment) => ReadonlyArray<string>
  readonly activation: (payload: unknown, context: EventFilterContext) => Record<string, unknown>
}

export const filterVariablesFor = (payload: FieldShape): FilterVariables => {
  if (payload.kind === "record" && !payload.nullable) return declaredVariables(payload)
  return dynamicVariables(payload)
}

const eventVariable = "event"

const eventSchema: ObjectSchema = {
  eventId: "string",
  name: "string",
  timestamp: "string",
  account: { id: "string", label: "string", identity: "string" }
}

const eventDeclaration: RegisterVariableDeclaration = { name: eventVariable, schema: eventSchema }

const declaredVariables = (payload: RecordShape): FilterVariables => {
  const declarations = [...payload.fields].map(([name, shape]) => declarationOf(name, shape))
  if (!payload.fields.has(eventVariable)) declarations.push(eventDeclaration)

  return {
    unlistedAreDyn: false,
    declare: (env) =>
      declarations.filter((declaration) => registered(env, declaration)).map(({ name }) => name),
    activation: (value, context) => ({ event: context, ...declaredFieldsOf(value, payload) })
  }
}

const dynamicVariables = (payload: FieldShape): FilterVariables => ({
  unlistedAreDyn: true,
  declare: (env) => {
    env.registerVariable(eventDeclaration)
    return [eventVariable]
  },
  activation: (value, context) => ({ ...fieldsOf(value, payload), event: context })
})

const registered = (env: Environment, declaration: RegisterVariableDeclaration): boolean => {
  try {
    env.registerVariable(declaration)
    return true
  } catch {
    return false
  }
}

const declarationOf = (name: string, shape: FieldShape): RegisterVariableDeclaration => {
  if (isPlainRecord(shape)) return { name, schema: objectSchemaOf(shape) }
  return { name, type: celTypeOf(shape) }
}

const isPlainRecord = (shape: FieldShape): shape is RecordShape =>
  shape.kind === "record" && !shape.nullable

const objectSchemaOf = (record: RecordShape): ObjectSchema =>
  Object.fromEntries([...record.fields].map(([name, shape]) => [name, objectFieldOf(shape)]))

const objectFieldOf = (shape: FieldShape): string | ObjectSchema => {
  if (isPlainRecord(shape)) return objectSchemaOf(shape)
  return celTypeOf(shape)
}

const celTypeOf = (shape: FieldShape): string => {
  if (shape.nullable) return "dyn"
  if (shape.kind === "list") return `list<${celTypeOf(shape.items)}>`
  if (shape.kind === "map") return `map<string, ${celTypeOf(shape.values)}>`
  if (shape.kind === "record") return "map<string, dyn>"
  return shape.kind
}

const declaredFieldsOf = (value: unknown, payload: RecordShape): Record<string, unknown> => {
  const fields = fieldsOf(value, payload)
  return Object.fromEntries(Object.entries(fields).filter(([name]) => payload.fields.has(name)))
}

const fieldsOf = (value: unknown, shape: FieldShape): Record<string, unknown> => {
  if (!isObject(value)) return {}
  return normalizedEntries(value, shape)
}

const normalizedEntries = (
  value: Record<string, unknown>,
  shape: FieldShape
): Record<string, unknown> =>
  Object.fromEntries(
    Object.entries(value).map(([key, entry]) => [key, normalized(entry, childShape(shape, key))])
  )

const normalized = (value: unknown, shape: FieldShape): unknown => {
  if (shape.kind === "int") return asInt(value)
  if (shape.kind === "list") return normalizedList(value, shape.items)
  if (hasChildren(shape) && isObject(value)) return normalizedEntries(value, shape)
  return value
}

const hasChildren = (shape: FieldShape): boolean => shape.kind === "record" || shape.kind === "map"

const normalizedList = (value: unknown, items: FieldShape): unknown => {
  if (!Array.isArray(value)) return value
  return value.map((item) => normalized(item, items))
}

const childShape = (shape: FieldShape, key: string): FieldShape => {
  if (shape.kind === "record") return shape.fields.get(key) ?? dynShape
  if (shape.kind === "map") return shape.values
  return dynShape
}

const asInt = (value: unknown): unknown => {
  if (typeof value === "number" && Number.isSafeInteger(value)) return BigInt(value)
  return value
}
