# CodeHighlighter

CodeHighlighter uses Tree-sitter's C runtime and generated C grammars. The Swift
bindings are implemented here; no third-party Swift binding or editor package is
used. Both native apps share this module.

## Ownership and APIs

- `TreeSitterGrammar` caches immutable languages and compiled queries. Each query
  execution owns its C cursor. `TreeSitterQuery` evaluates text predicates and
  properties after the C runtime returns structural matches.
- `TreeSitterDocument` owns a parser, syntax tree, UTF-16 buffer, line index, and
  embedded-language documents. Destruction releases all mutable C handles.
- `CodeHighlightDocument` serializes a document's edits in an actor. `update`
  accepts actual replaced ranges and inserted text; callers with snapshots can
  omit edits. Results contain a revision, an invalidated range, and styled spans.
- Apply a result only to its matching document revision. Reset syntax attributes
  in the invalidated range before applying spans, then call `acknowledge`.
  Unacknowledged invalidations are translated through later edits so a discarded
  result cannot leave stale colors behind.
- `CodeHighlighter.highlight` is the snapshot/line-token adapter used by chat and
  diffs. Streaming blocks retain a document session; completion releases it.
  Settled results have byte and entry limits.

Native text-storage ranges are UTF-16 code units. C byte offsets and point columns
are twice that size. Parser input is explicitly UTF-16 little endian. The buffer
remains alive for the synchronous C parse callback; no pointers into Swift strings
escape it. Parsing and query execution run in the document actor, and native text
attributes are applied on the main actor.

## Highlighting and themes

Queries assign syntax labels independently of colors. Theme resolution maps those
labels onto existing TextMate theme rules and supports foreground, bold, and
italic. Theme changes reuse the syntax tree. Overlapping captures use injection
depth, explicit priority, range specificity, label specificity, and query order.

Invalidation includes the containing top-level construct and structural changed
ranges, plus the edited text even if tree shape did not change. Local-binding
queries invalidate their enclosing scope. This deliberately favors correctness
over minimizing every patch; edits to a large function or global scope can still
invalidate a large range.

Embedded Markdown and HTML languages use the same grammars and theme mapping.
Unrecognized injected languages retain their parent highlighting. This is syntax
highlighting, not project-wide type resolution or language-server functionality.

## Updating dependencies

`Vendor/manifest.json` records upstream repositories and exact revisions. The
runtime is Tree-sitter **0.26.13** (`d97971e24500218865c05ed1febdee2acf41bae1`).
Swift and SQL use pinned upstream npm source archives, including checksums,
because generated parsers are distributed there. Only C sources, headers, queries,
and licenses are consumed; there is no npm or JavaScript runtime dependency.

After intentionally updating a manifest entry, run:

```sh
python3 scripts/vendor-tree-sitter.py
swift test --package-path packages/swift --filter 'CodeHighlighterTests|TreeSitterDocumentTests'
```

The updater refreshes sources, copies the bundled queries, and assembles third-party
notices. Normal builds require no parser generator or grammar downloads. Preserve
upstream generated sources rather than editing parser tables manually.

## Verification

Tests compile every bundled grammar/query pair, preserve source round trips and
existing theme behavior, compare incremental patches with fresh highlights after
edits, check skipped revisions and theme-only updates, and exercise nested
languages. Timing comparisons belong in a separate release benchmark, not test
pass/fail thresholds.
