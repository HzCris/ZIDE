# zigmap — architecture map generator for Zig codebases

Build a command-line tool, in Zig, that produces a navigable architecture map of a Zig project as a single self-contained HTML file. The map's structure comes from ground truth (the `@import` graph and ZLS symbol/reference data); a model is used only to name and describe things, never to invent structure.

Read this whole file before writing code. Ask about anything marked **ASK** before proceeding.

## Environment

- Zig version: **ASK** — run `zig version` and pin to exactly that. Do not target master.
- ZLS binary: **ASK** for the path. It must match the Zig version. The tool takes it as `--zls <path>`; default to `zls` on PATH.
- Primary OS is Windows (PowerShell). Keep it portable, but file URIs (`file:///C:/...`), backslashes, and CRLF must work on Windows first.
- No telemetry. No network access of any kind except the optional model call in the `--name` step, and only to the endpoint the user configures.
- No git dependency. The tool walks directories; it must work on a folder that has never been `git init`ed.

## Why the HTML viewer is a runtime file, not just embedded

The user dislikes build-compile-tweak loops for GUIs. The viewer is plain HTML/CSS/JS and must be iterable without recompiling Zig:

- Ship a default template embedded with `@embedFile("viewer/template.html")`.
- Also accept `--template <path>` to use an external template at runtime. Editing that file and re-running `zigmap map` must be enough to see changes. No Zig rebuild.
- The template contains a single placeholder (e.g. `/*__ZIGMAP_DATA__*/`) where the JSON is inlined.

## Outputs

Written to `<root>/zigmap/` unless `--out <dir>` is given:

- `analysis.json` — the full graph plus labels plus cache metadata. Stable schema; other tools may read it.
- `map.html` — self-contained. Inline JS and CSS only. No CDN, no fonts, no fetch. Must open from disk on a phone or tablet with no server.
- `cache/` — per-file results keyed by content hash so re-runs only redo changed files.

## Pipeline

Build it in this order. Each step must produce a usable output before the next begins.

### Step 1 — Discovery and import graph (no ZLS yet)

- Walk `--roots` (default `src`) for `.zig` files. Ignore `.git`, `zig-cache`, `.zig-cache`, `zig-out`, and anything in `--ignore` (comma-separated globs).
- For every file, extract `@import("...")` calls by text scan. Imports ending in `.zig` are resolved relative to the importing file's directory into file→file edges. Anything else (`std`, `builtin`, package names from build.zig) is recorded as an external dependency, not an edge.
- Record per file: path, line count, list of imports, list of importers.
- Emit `analysis.json` (files and import edges only) and a `map.html` that shows files grouped by directory with import edges. This is already a useful map and is the deliverable for Step 1.

### Step 2 — ZLS client and the gate

Implement an LSP client over stdio using `std.process.Child` and `std.json`:

- Spawn ZLS with `--config-path <tmpfile>` where the temp config sets `"skip_std_references": true` (this makes reference lookups only search user code).
- `initialize` with `rootUri` for the project, `initialized`, then `textDocument/didOpen` for every discovered file with its contents.
- `textDocument/documentSymbol` per file. Keep functions (`Function`, `Method`) and containers (`Struct`, `Enum`, `Union`, `Namespace`, `Class`) with their full ranges and selection ranges, including nesting (functions inside structs, structs inside functions).
- `textDocument/references` (`includeDeclaration: false`) on each function's selection range. Map every returned location back to the enclosing function in that file using the symbol ranges from documentSymbol. That mapping is the call edge: enclosing function → referenced function.
- Handle: request timeouts, ZLS crashes (restart once, then fail loudly), server-side errors per request (log and continue, never abort the run for one symbol), Windows path/URI conversion.
- Progress to stderr: files opened, symbols found, references queried, elapsed.

Add a `gate` subcommand before wiring references into the graph:

```
zigmap gate <root> --zls <path> --sample 50
```

It opens all files, pulls all document symbols, then queries references for a random sample of N functions spread across directories. It prints: total files, total functions, total containers, and for the sample: how many functions had at least one caller, how many had a caller in a different file, mean/max references per function, and wall time. This is the go/no-go for whether ZLS reference quality is good enough on a given project. Ship this before Step 3.

### Step 3 — Graph and clustering

- Nodes: functions (id = `path:name:line`), containers, files. Edges: calls (from references, with counts), contains (function in container in file), imports (from Step 1).
- Compute in-degree and out-degree for functions and files. Persist to `analysis.json`.
- Cluster the function call graph into subsystems. Use Louvain or label propagation (implement in Zig; a few hundred lines; deterministic given a fixed seed). Seed or constrain by directory so that clusters don't cut across unrelated folders without strong evidence. Output: cluster id → member functions and files. Clusters are the top-level boxes in the map.
- Aggregate edges between clusters with weights (number of underlying call edges).
- `map.html` now shows clusters as top-level boxes with weighted edges; clicking a cluster expands to its files; clicking a file expands to its functions with call edges. Unlabeled clusters are named `cluster-N` until Step 4.

### Step 4 — Optional model naming (`--name`)

- Endpoint is OpenAI-compatible chat completions. Config: `--api-base` (default `https://openrouter.ai/api/v1`), `--model`, API key from env `ZIGMAP_API_KEY`. Nothing is sent unless `--name` is passed.
- The model never sees source code. Per cluster, send a symbol table: file paths, function names and signatures, container names, in/out-degree, top callers/callees by name, and the cluster's aggregated edges to other clusters. Ask for strict JSON: `{ "name": ..., "description": one line, "files": { "<path>": one line } }`.
- Validate the JSON. Attach labels only to nodes that already exist. Reject and log any file or function the model mentions that isn't in the cluster. The model cannot add or remove nodes or edges under any circumstance.
- Cache labels in `analysis.json` keyed by a hash of the cluster's membership. `--name` on a re-run only re-labels clusters whose membership changed.
- Keep prompt size small; this step should cost cents, not dollars, on a 100k-line project.

### Step 5 — Viewer polish

`map.html` requirements:

- Three levels: clusters → files → functions. Expand/collapse by click. Edges aggregate at whatever level is shown.
- Side panel for the selected node: name, description (if named), file path, callers, callees, imports/importers, line count. Clicking any name in the panel selects that node and re-centers.
- Search box filtering by name or path.
- URL hash navigation: `map.html#src/renderer/mesh.zig` selects and centers that file; `map.html#src/renderer/mesh.zig:upload` selects that function. This is how an editor keybinding opens the map "at the current file".
- Layout: force-directed or layered, computed in JS on load; must be readable for ~50 clusters and ~500 files without manual arranging. Precompute positions into `analysis.json` if load-time layout is too slow.
- Dark theme by default, light theme available. Keyboard: arrows to move selection, Enter to expand, Esc to go up a level, `/` to focus search.
- Zero external requests. Verify by opening it with the network disabled.

## CLI

```
zigmap full <root> [--zls <path>] [--roots src,lib] [--ignore <globs>] [--out <dir>] [--name] [--api-base <url>] [--model <id>] [--template <html>]
zigmap map  <root> [--out <dir>] [--template <html>]      # re-render from existing analysis.json, no ZLS, no network
zigmap gate <root> [--zls <path>] [--sample N]
```

- Non-zero exit on failure, with a one-line reason on stderr.
- `full` without `--name` must complete with no network access at all.

## Testing

- A `fixtures/tiny` Zig project with a known call graph (about ten files, thirty functions, a couple of nested structs, one generic `fn Foo(comptime T: type) type`, one `anytype` call). Golden `analysis.json` for it. The test asserts every expected edge is present and no unexpected edges exist.
- The tool must map itself: `zigmap full .` on its own repo is a required test.
- `gate` output on the fixture is checked for the expected counts.

## Non-goals (for now)

- No editor integration. A future ZIDE Lua extension will do two things only: run `zigmap full` and open `map.html#<current file>`. Design nothing for it beyond the hash navigation.
- No C support yet, but keep the LSP client server-agnostic (language id, file extensions, and server launch are parameters) so a `clangd` configuration can be added later without touching the graph or viewer code.
- No incremental beyond the content-hash cache.
- No telemetry, ever.

## Working agreement

- Start with Step 1 and stop when `map.html` opens and shows the import graph. Show it before moving on.
- Then Step 2's `gate`. Run it on the project the user names and report the numbers before building Step 3, because the numbers decide whether Step 3 is worth building on this ZLS version.
- If the Zig std APIs for HTTP or JSON differ from what you expect for the pinned version, read the std source for that version rather than guessing.
- Prefer boring code. This is a tool the user will maintain in Zig across version bumps; every clever abstraction is a future migration cost.
