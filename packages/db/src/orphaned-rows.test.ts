import Database from "better-sqlite3"
import { describe, expect, it, onTestFinished } from "vitest"

import { resolveOrphanedRows } from "./orphaned-rows.js"

const schemaSql = `
  create table parents (id text primary key);
  create table children (
    id text primary key,
    parent_id text not null references parents(id) on delete cascade
  );
  create table grandchildren (
    id text primary key,
    child_id text not null references children(id) on delete cascade
  );
  create table links (id text primary key, parent_id text references parents(id) on delete set null);
  create table fallbacks (
    id text primary key,
    parent_id text not null default 'kept' references parents(id) on delete set default
  );
  create table blockers (id text primary key, parent_id text references parents(id));
  create table pairs (a text, b text, primary key (a, b));
  create table pair_notes (
    id text primary key, a text, b text,
    foreign key (a, b) references pairs(a, b) on delete cascade
  );
`

const seedSql = `
  insert into parents values ('kept'), ('dropped');
  insert into children values ('kept-child', 'kept'), ('dropped-child', 'dropped');
  insert into grandchildren values ('kept-grandchild', 'kept-child'),
    ('dropped-grandchild', 'dropped-child');
  insert into links values ('kept-link', 'kept'), ('dropped-link', 'dropped'), ('no-link', null);
  insert into fallbacks values ('kept-fallback', 'kept'), ('dropped-fallback', 'dropped');
  insert into pairs values ('x', 'kept'), ('x', 'dropped');
  insert into pair_notes values ('kept-note', 'x', 'kept'), ('dropped-note', 'x', 'dropped');
`

const migratingDatabase = (): Database.Database => {
  const sqlite = new Database(":memory:")
  onTestFinished(() => {
    sqlite.close()
  })
  sqlite.exec(schemaSql)
  sqlite.exec(seedSql)
  sqlite.pragma("foreign_keys = OFF")
  return sqlite
}

const tableRows = (sqlite: Database.Database, table: string): ReadonlyArray<unknown> =>
  sqlite.prepare(`select * from ${table} order by id`).all()

const everyTable = ["children", "grandchildren", "links", "fallbacks", "blockers", "pair_notes"]

const snapshot = (sqlite: Database.Database): Record<string, ReadonlyArray<unknown>> =>
  Object.fromEntries(everyTable.map((table) => [table, tableRows(sqlite, table)]))

describe("resolveOrphanedRows", () => {
  it("applies each foreign key's delete rule to orphans, through every level, and nothing else", () => {
    const sqlite = migratingDatabase()
    sqlite.exec("delete from parents where id = 'dropped'; delete from pairs where b = 'dropped'")

    const resolutions = resolveOrphanedRows(sqlite)

    expect(snapshot(sqlite)).toEqual({
      children: [{ id: "kept-child", parent_id: "kept" }],
      grandchildren: [{ id: "kept-grandchild", child_id: "kept-child" }],
      links: [
        { id: "dropped-link", parent_id: null },
        { id: "kept-link", parent_id: "kept" },
        { id: "no-link", parent_id: null }
      ],
      fallbacks: [
        { id: "dropped-fallback", parent_id: "kept" },
        { id: "kept-fallback", parent_id: "kept" }
      ],
      blockers: [],
      pair_notes: [{ id: "kept-note", a: "x", b: "kept" }]
    })
    expect(resolutions).toEqual(
      expect.arrayContaining([
        { table: "children", columns: ["parent_id"], parent: "parents", rule: "CASCADE", rows: 1 },
        {
          table: "grandchildren",
          columns: ["child_id"],
          parent: "children",
          rule: "CASCADE",
          rows: 1
        },
        { table: "links", columns: ["parent_id"], parent: "parents", rule: "SET NULL", rows: 1 },
        {
          table: "fallbacks",
          columns: ["parent_id"],
          parent: "parents",
          rule: "SET DEFAULT",
          rows: 1
        },
        { table: "pair_notes", columns: ["a", "b"], parent: "pairs", rule: "CASCADE", rows: 1 }
      ])
    )
    expect(resolutions).toHaveLength(5)
  })

  it("changes nothing when no row is orphaned", () => {
    const sqlite = migratingDatabase()
    const before = snapshot(sqlite)

    expect(resolveOrphanedRows(sqlite)).toEqual([])
    expect(snapshot(sqlite)).toEqual(before)
  })

  it("refuses an orphan on a foreign key with no delete rule", () => {
    const sqlite = migratingDatabase()
    sqlite.exec("insert into blockers values ('blocked', 'missing')")

    expect(() => resolveOrphanedRows(sqlite)).toThrow(
      /no delete rule resolves: \[\{"table":"blockers","columns":\["parent_id"\],"parent":"parents","onDelete":"NO ACTION","rows":1,"rowids":\[1\]\}\]/
    )
  })

  it("lets a cascade remove a row that also had an orphan with no delete rule", () => {
    const sqlite = migratingDatabase()
    sqlite.exec(`
      create table both_keys (
        id text primary key,
        parent_id text references parents(id) on delete cascade,
        blocker_id text references blockers(id)
      );
      insert into both_keys values ('both', 'dropped', 'missing');
      delete from parents where id = 'dropped';
    `)

    resolveOrphanedRows(sqlite)

    expect(tableRows(sqlite, "both_keys")).toEqual([])
  })

  it("refuses a set default whose default is itself orphaned instead of looping", () => {
    const sqlite = migratingDatabase()
    sqlite.exec("delete from parents")

    expect(() => resolveOrphanedRows(sqlite)).toThrow(
      /"table":"fallbacks".*"onDelete":"SET DEFAULT"/
    )
  })
})
