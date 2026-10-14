import assert from "node:assert/strict"
import test from "node:test"

import { findComments, removeComments } from "./check-comments.mjs"

const strip = (path, text) => removeComments(text, findComments(path, text))

test("comment markers inside strings, heredocs, and raw strings are code", () => {
  const shell = [
    "#!/usr/bin/env bash",
    "echo \"# not\" '# not' ${#items[@]} $#",
    "cat <<EOF",
    "# heredoc body",
    "EOF",
    ""
  ].join("\n")
  assert.equal(strip("run.sh", shell), shell)

  const rust = [
    'let pattern = r#"// not "quoted" /* either */"#;',
    "fn first<'a>(value: &'a str) -> char { '/' }",
    ""
  ].join("\n")
  assert.equal(strip("lib.rs", rust), rust)

  const toml = ['url = "https://example.com/#anchor"', "literal = '# not'", ""].join("\n")
  assert.equal(strip("fly.toml", toml), toml)
})

test("YAML strips shell comments inside run scripts but keeps other block scalars", () => {
  const workflow = [
    "jobs:",
    "  build:",
    "    steps:",
    "      - uses: actions/checkout@abc # v7",
    "      - run: |",
    "          # explain",
    '          echo "#1"',
    "        env:",
    "          NOTES: |",
    "            # literal text",
    ""
  ].join("\n")
  assert.equal(
    strip("build.yml", workflow),
    [
      "jobs:",
      "  build:",
      "    steps:",
      "      - uses: actions/checkout@abc",
      "      - run: |",
      '          echo "#1"',
      "        env:",
      "          NOTES: |",
      "            # literal text",
      ""
    ].join("\n")
  )
})

test("tool directives stay, without their reasons", () => {
  const shell = ["# shellcheck disable=SC2086 # word list", "echo $LIST", ""].join("\n")
  assert.equal(strip("run.sh", shell), ["# shellcheck disable=SC2086", "echo $LIST", ""].join("\n"))
  const sql = ["DROP INDEX a;--> statement-breakpoint", "-- why", "CREATE INDEX a ON t (c);", ""]
  assert.equal(
    strip("0001.sql", sql.join("\n")),
    ["DROP INDEX a;--> statement-breakpoint", "CREATE INDEX a ON t (c);", ""].join("\n")
  )
})

test("removing a comment block leaves one blank line between sections and none inside braces", () => {
  const source = [
    "// header",
    "",
    "#include <a.h>",
    "",
    "// section",
    "",
    "int f() {",
    "  // first",
    "  return 1; // trailing",
    "",
    "  // last",
    "}",
    ""
  ].join("\n")
  assert.equal(
    strip("f.c", source),
    ["#include <a.h>", "", "int f() {", "  return 1;", "}", ""].join("\n")
  )
})
