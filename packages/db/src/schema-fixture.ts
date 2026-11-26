import type Database from "better-sqlite3"

import { integer, nullable, rowReader, text } from "./row-reader.js"

export interface SchemaFixture {
  readonly seedRound: () => void
}

export type ColumnValues = Readonly<Record<string, unknown>>

export const schemaFixture = (
  sqlite: Database.Database,
  appValues: ColumnValues = {}
): SchemaFixture => {
  let generation = 0
  return {
    seedRound: () => {
      const schema = readSchema(sqlite, appValues)
      for (const shape of roundShapes(schema)) {
        generation += 1
        seedGeneration(sqlite, schema, shape, generation)
      }
    }
  }
}

interface Column {
  readonly name: string
  readonly affinity: "integer" | "real" | "text" | "blob"
  readonly notNull: boolean
  readonly hasDefault: boolean
  readonly allowed: unknown
}

interface ForeignKey {
  readonly parent: string
  readonly from: ReadonlyArray<string>
  readonly to: ReadonlyArray<string | null>
}

interface Table {
  readonly name: string
  readonly columns: ReadonlyArray<Column>
  readonly primaryKey: ReadonlyArray<string>
  readonly uniqueColumns: ReadonlySet<string>
  readonly foreignKeys: ReadonlyArray<ForeignKey>
}

type Schema = ReadonlyMap<string, Table>

const keyRange = 1_000_000

const keyRanges = 1_000_000

const roundShapes = (schema: Schema): ReadonlyArray<ReadonlySet<string>> => [
  new Set(schema.keys()),
  ...[...schema.keys()].map((table) => withAncestors(schema, table))
]

const withAncestors = (schema: Schema, table: string): ReadonlySet<string> => {
  const found = new Set<string>()
  const visit = (name: string): void => {
    if (found.has(name) || !schema.has(name)) return

    found.add(name)
    for (const key of schema.get(name)?.foreignKeys ?? []) visit(key.parent)
  }
  visit(table)
  return found
}

const seedGeneration = (
  sqlite: Database.Database,
  schema: Schema,
  shape: ReadonlySet<string>,
  generation: number
): void => {
  for (const name of shape) {
    const table = schema.get(name)
    if (table !== undefined) insertRow(sqlite, schema, table, generation)
  }
}

const insertRow = (
  sqlite: Database.Database,
  schema: Schema,
  table: Table,
  generation: number
): void => {
  const values = new Map<string, unknown>()
  for (const column of table.columns) {
    const value = columnValue(schema, table, column, generation, 0)
    if (value !== omitted) values.set(column.name, value)
  }
  const columns = [...values.keys()]
  try {
    sqlite.prepare(fixtureSql.insert(table.name, columns)).run(...values.values())
  } catch (cause) {
    if (isSingletonConflict(cause)) return
    throw new Error(`The schema fixture could not seed ${table.name}: ${String(cause)}`, { cause })
  }
}

const isSingletonConflict = (cause: unknown): boolean =>
  cause instanceof Error && "code" in cause && singletonConflicts.has(String(cause.code))

const singletonConflicts = new Set(["SQLITE_CONSTRAINT_PRIMARYKEY", "SQLITE_CONSTRAINT_UNIQUE"])

const omitted = Symbol("omitted")

const maxReferenceDepth = 16

const columnValue = (
  schema: Schema,
  table: Table,
  column: Column,
  generation: number,
  depth: number
): unknown => {
  const parentColumn = referencedColumn(schema, table, column.name)
  if (parentColumn !== undefined && depth < maxReferenceDepth) {
    return columnValue(schema, parentColumn.table, parentColumn.column, generation, depth + 1)
  }

  if (column.allowed !== undefined) return column.allowed
  if (isKey(schema, table, column.name)) return keyValue(table, column, generation)
  if (column.hasDefault) return omitted
  if (!column.notNull) return null
  return zeroValues[column.affinity]
}

const zeroValues: Readonly<Record<Column["affinity"], unknown>> = {
  integer: 0,
  real: 0,
  text: "",
  blob: Buffer.alloc(0)
}

const keyValue = (table: Table, column: Column, generation: number): unknown => {
  const name = `${table.name}.${column.name}`
  if (column.affinity === "integer" || column.affinity === "real") {
    return keyRangeOf(name) * keyRange + generation
  }
  return `${name}.${generation}`
}

const keyRangeOf = (name: string): number => {
  let hash = 0
  for (let index = 0; index < name.length; index += 1) {
    hash = (hash * 31 + name.charCodeAt(index)) % keyRanges
  }
  return hash + 1
}

interface ParentColumn {
  readonly table: Table
  readonly column: Column
}

const referencedColumn = (schema: Schema, table: Table, name: string): ParentColumn | undefined => {
  for (const key of table.foreignKeys) {
    const index = key.from.indexOf(name)
    const parent = schema.get(key.parent)
    if (index === -1 || parent === undefined) continue

    const parentName = key.to[index] ?? parent.primaryKey[index]
    const column = parent.columns.find((candidate) => candidate.name === parentName)
    if (column !== undefined) return { table: parent, column }
  }
  return undefined
}

const isKey = (schema: Schema, table: Table, name: string): boolean =>
  table.primaryKey.includes(name) ||
  table.uniqueColumns.has(name) ||
  [...schema.values()].some((child) =>
    child.foreignKeys.some(
      (key) => key.parent === table.name && parentColumns(table, key).includes(name)
    )
  )

const parentColumns = (table: Table, key: ForeignKey): ReadonlyArray<string | undefined> =>
  key.to.map((column, index) => column ?? table.primaryKey[index])

const readSchema = (sqlite: Database.Database, appValues: ColumnValues): Schema =>
  new Map(
    tableRows
      .all(sqlite.prepare(fixtureSql.tables).all())
      .map((row) => [row.name, readTable(sqlite, row.name, row.sql, appValues)])
  )

const readTable = (
  sqlite: Database.Database,
  name: string,
  sql: string,
  appValues: ColumnValues
): Table => {
  const columns = columnRows.all(sqlite.prepare(fixtureSql.columns).all(name))
  return {
    name,
    columns: columns.map((row) => ({
      name: row.name,
      affinity: affinityOf(row.type),
      notNull: row.notnull === 1,
      hasDefault: row.dflt_value !== null,
      allowed: appValues[`${name}.${row.name}`] ?? allowedValue(sql, row.name)
    })),
    primaryKey: columns
      .filter((row) => row.pk > 0)
      .toSorted((left, right) => left.pk - right.pk)
      .map((row) => row.name),
    uniqueColumns: new Set(
      nameRows.all(sqlite.prepare(fixtureSql.uniqueColumns).all(name)).map((row) => row.name)
    ),
    foreignKeys: readForeignKeys(sqlite, name)
  }
}

const readForeignKeys = (sqlite: Database.Database, table: string): ReadonlyArray<ForeignKey> => {
  const keys = new Map<number, ForeignKey>()
  for (const row of foreignKeyRows.all(sqlite.prepare(fixtureSql.foreignKeys).all(table))) {
    const key = keys.get(row.id)
    keys.set(row.id, {
      parent: row.table,
      from: [...(key?.from ?? []), row.from],
      to: [...(key?.to ?? []), row.to]
    })
  }
  return [...keys.values()]
}

const affinityOf = (declared: string): Column["affinity"] => {
  const type = declared.toLowerCase()
  if (type.includes("int")) return "integer"
  if (/real|floa|doub/.test(type)) return "real"
  if (type === "" || type.includes("blob")) return "blob"
  return "text"
}

const allowedValue = (tableSql: string, column: string): unknown => {
  const check = new RegExp(
    `check\\s*\\(\\s*"?${column}"?\\s*(?:=|in\\s*\\()\\s*(?:'([^']*)'|(-?\\d+))`,
    "i"
  ).exec(tableSql)
  if (check === null) return undefined
  if (check[1] !== undefined) return check[1]
  return Number(check[2])
}

const quoted = (identifier: string): string => `"${identifier.replaceAll('"', '""')}"`

const fixtureSql = {
  tables: `select name, sql from sqlite_master
            where type = 'table' and name not like 'sqlite_%' and name != 'schema_migrations'
              and sql not like 'create virtual table%'
            order by name`,
  columns:
    'select name, type, "notnull", dflt_value, pk from pragma_table_xinfo(?) where hidden = 0',
  uniqueColumns: `select distinct info.name as name
                    from pragma_index_list(?) list, pragma_index_info(list.name) info
                   where list."unique" = 1 and info.name is not null`,
  insert: (table: string, columns: ReadonlyArray<string>) =>
    `insert into ${quoted(table)} (${columns.map(quoted).join(", ")})
       values (${columns.map(() => "?").join(", ")})`,
  foreignKeys: `select id, "table", "from", "to" from pragma_foreign_key_list(?) order by id, seq`
}

const tableRows = rowReader({ name: text, sql: text })

const nameRows = rowReader({ name: text })

const columnRows = rowReader({
  name: text,
  type: text,
  notnull: integer,
  dflt_value: nullable(text),
  pk: integer
})

const foreignKeyRows = rowReader({ id: integer, table: text, from: text, to: nullable(text) })
