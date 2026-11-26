import type Database from "better-sqlite3"

import { integer, nullable, rowReader, text } from "./row-reader.js"

export interface OrphanResolution {
  readonly table: string
  readonly columns: ReadonlyArray<string>
  readonly parent: string
  readonly rule: ResolvableRule
  readonly rows: number
}

type ResolvableRule = "CASCADE" | "SET NULL" | "SET DEFAULT"

export const resolveOrphanedRows = (sqlite: Database.Database): ReadonlyArray<OrphanResolution> => {
  const keys = foreignKeyCatalog(sqlite)
  const resolutions = new Map<string, OrphanResolution>()
  const resolved = new Set<string>()
  for (;;) {
    const orphans = groupOrphans(foreignKeyViolations(sqlite), keys)
    const resolvable = orphans.filter((group) => isResolvable(group, resolved))
    if (resolvable.length === 0) {
      refuseRemaining(orphans)
      return [...resolutions.values()]
    }

    for (const group of resolvable) {
      applyDeleteRule(sqlite, group)
      recordResolution(resolutions, resolved, group)
    }
  }
}

export const describeOrphanResolution = (resolution: OrphanResolution): string =>
  `${resolution.table}(${resolution.columns.join(", ")}) -> ${resolution.parent}: ` +
  `${ruleOutcomes[resolution.rule]} ${resolution.rows} ${resolution.rows === 1 ? "row" : "rows"}`

interface ForeignKey {
  readonly table: string
  readonly id: number
  readonly parent: string
  readonly columns: ReadonlyArray<string>
  readonly onDelete: string
}

interface OrphanGroup {
  readonly key: ForeignKey
  readonly rowids: ReadonlyArray<number | null>
}

interface ResolvableGroup {
  readonly key: ForeignKey & { readonly onDelete: ResolvableRule }
  readonly rowids: ReadonlyArray<number>
}

const ruleOutcomes: Readonly<Record<ResolvableRule, string>> = {
  CASCADE: "deleted",
  "SET NULL": "nulled",
  "SET DEFAULT": "reset to default"
}

const resolvableRules: ReadonlySet<string> = new Set(Object.keys(ruleOutcomes))

const isResolvable = (
  group: OrphanGroup,
  resolved: ReadonlySet<string>
): group is ResolvableGroup =>
  resolvableRules.has(group.key.onDelete) &&
  group.rowids.every((rowid) => rowid !== null && !resolved.has(rowKey(group.key, rowid)))

const rowKey = (key: ForeignKey, rowid: number): string =>
  `${key.table}\u0000${key.id}\u0000${rowid}`

const applyDeleteRule = (sqlite: Database.Database, group: ResolvableGroup): void => {
  const rowids = JSON.stringify(group.rowids)
  const table = quoted(group.key.table)
  if (group.key.onDelete === "CASCADE") {
    sqlite.prepare(orphanSql.delete(table)).run(rowids)
    return
  }

  const assignments = group.key.columns
    .map((column) => `${quoted(column)} = ${replacementFor(sqlite, group.key, column)}`)
    .join(", ")
  sqlite.prepare(orphanSql.update(table, assignments)).run(rowids)
}

const replacementFor = (sqlite: Database.Database, key: ResolvableGroup["key"], column: string) => {
  if (key.onDelete === "SET NULL") return "null"

  return `(${columnDefault(sqlite, key.table, column) ?? "null"})`
}

const recordResolution = (
  resolutions: Map<string, OrphanResolution>,
  resolved: Set<string>,
  group: ResolvableGroup
): void => {
  for (const rowid of group.rowids) resolved.add(rowKey(group.key, rowid))
  const id = `${group.key.table}\u0000${group.key.id}`
  const rows = (resolutions.get(id)?.rows ?? 0) + group.rowids.length
  resolutions.set(id, {
    table: group.key.table,
    columns: group.key.columns,
    parent: group.key.parent,
    rule: group.key.onDelete,
    rows
  })
}

const reportedRowids = 20

const refuseRemaining = (orphans: ReadonlyArray<OrphanGroup>): void => {
  if (orphans.length === 0) return

  const details = orphans.map((group) => ({
    table: group.key.table,
    columns: group.key.columns,
    parent: group.key.parent,
    onDelete: group.key.onDelete,
    rows: group.rowids.length,
    rowids: group.rowids.slice(0, reportedRowids)
  }))
  throw new Error(
    `Migration left foreign key violations that no delete rule resolves: ${JSON.stringify(details)}`
  )
}

const groupOrphans = (
  violations: ReadonlyArray<Violation>,
  keys: ForeignKeyCatalog
): ReadonlyArray<OrphanGroup> => {
  const groups = new Map<string, { key: ForeignKey; rowids: Array<number | null> }>()
  for (const violation of violations) {
    const key = keys.find(violation.table, violation.fkid)
    const id = `${key.table}\u0000${key.id}`
    const group = groups.get(id) ?? { key, rowids: [] }
    group.rowids.push(violation.rowid)
    groups.set(id, group)
  }
  return [...groups.values()]
}

interface ForeignKeyCatalog {
  readonly find: (table: string, id: number) => ForeignKey
}

const foreignKeyCatalog = (sqlite: Database.Database): ForeignKeyCatalog => {
  const byTable = new Map<string, ReadonlyArray<ForeignKey>>()
  const keysOf = (table: string): ReadonlyArray<ForeignKey> => {
    const known = byTable.get(table)
    if (known !== undefined) return known

    const keys = foreignKeysOf(sqlite, table)
    byTable.set(table, keys)
    return keys
  }
  return {
    find: (table, id) => {
      const key = keysOf(table).find((candidate) => candidate.id === id)
      if (key === undefined) throw new Error(`Unknown foreign key ${id} on ${table}`)
      return key
    }
  }
}

const foreignKeysOf = (sqlite: Database.Database, table: string): ReadonlyArray<ForeignKey> => {
  const keys = new Map<number, ForeignKey>()
  const rows = foreignKeyRows.all(sqlite.prepare(orphanSql.foreignKeys).all(table))
  for (const row of rows) {
    const key = keys.get(row.id)
    const columns = [...(key?.columns ?? []), row.from]
    keys.set(row.id, { table, id: row.id, parent: row.table, columns, onDelete: row.on_delete })
  }
  return [...keys.values()]
}

const columnDefault = (sqlite: Database.Database, table: string, column: string): string | null =>
  columnDefaultRows.maybe(sqlite.prepare(orphanSql.columnDefault).get(table, column))?.dflt_value ??
  null

interface Violation {
  readonly table: string
  readonly rowid: number | null
  readonly fkid: number
}

const foreignKeyViolations = (sqlite: Database.Database): ReadonlyArray<Violation> =>
  violationRows.all(sqlite.prepare(orphanSql.violations).all())

const quoted = (identifier: string): string => `"${identifier.replaceAll('"', '""')}"`

const orphanSql = {
  violations: "pragma foreign_key_check",
  foreignKeys: `select id, seq, "table", "from", on_delete
                  from pragma_foreign_key_list(?) order by id, seq`,
  columnDefault: "select dflt_value from pragma_table_info(?) where name = ?",
  delete: (table: string) => `delete from ${table} where rowid in (select value from json_each(?))`,
  update: (table: string, assignments: string) =>
    `update ${table} set ${assignments} where rowid in (select value from json_each(?))`
}

const violationRows = rowReader({ table: text, rowid: nullable(integer), fkid: integer })

const foreignKeyRows = rowReader({
  id: integer,
  seq: integer,
  table: text,
  from: text,
  on_delete: text
})

const columnDefaultRows = rowReader({ dflt_value: nullable(text) })
