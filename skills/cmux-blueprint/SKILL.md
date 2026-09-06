---
name: cmux-blueprint
description: Draw and read the Blueprint diagram canvas docked below the current cmux terminal. Use when designing or explaining an architecture, a data flow, or a plan the user should see as a diagram, when the user says "draw", "diagram", "sketch", "blueprint", or "see the canvas", or when the user has sketched something for you to read.
---

# Blueprint canvas with cmux

Every cmux terminal can have a Blueprint drawer: an Excalidraw canvas below the
terminal that you draw into and the user sketches on. Inside a cmux terminal
with the Blueprint beta on, the `cmux-blueprint` MCP tools are attached to your
session; the `cmux blueprint` CLI does the same from a shell.

## When to draw

- After you and the user agree on an architecture, before a large refactor,
  or when you explain a data flow. One diagram per concern.
- Update the canvas on decisions, not on every file edit.
- Keep it small: under about 40 nodes. Use `append` for a sub-diagram instead
  of cramming one drawing.
- Prefer Mermaid (`blueprint_show_mermaid`); raw Excalidraw elements only when
  exact shapes and positions matter.

## Read before you write

1. `blueprint_state` first. It is cheap and returns `revision` and a compact
   summary (one line per element, arrows as edges, sketches collapsed).
2. If `updated_by` is `user`, or the summary shows a `sketch:` line you did not
   draw, read it with `blueprint_get` (`summary`) and say what you took from it
   before drawing over it.
3. Pass `base_revision` from that read to every mutation. A `conflict` error
   means the canvas changed since; read again and retry. Never loop on it.

## Draw

```text
blueprint_show_mermaid  mermaid="flowchart LR\n  CLI --> Socket --> App"  mode=replace  base_revision=3
blueprint_show_mermaid  mermaid="sequenceDiagram\n  ..."               mode=append   base_revision=4
blueprint_update        ops=[{op: upsert, element: {id: "...", ...}}, {op: delete, id: "..."}]
blueprint_export_image  format=png  path=/abs/path/docs/architecture.png
```

If the drawer is closed, drawing opens it (the user can turn that off; then
the drawer shows an "updated by agent" badge instead). `blueprint_show` and
`blueprint_hide` never move keyboard focus.

## From a shell

```bash
cmux blueprint state
cmux blueprint mermaid diagram.mmd --base-revision 3
echo 'flowchart LR; A-->B' | cmux blueprint mermaid - --append
cmux blueprint get --format mermaid
cmux blueprint export --format png --out docs/architecture.png
cmux blueprint ops ops.json
```

The target is the calling terminal; `--surface`, `--workspace`, `--window`
pick another one. `cmux blueprint --help` lists everything.

## When the user sends the canvas to you

"Send to Terminal" pastes a block into your prompt: a headline with the
revision and element count, a `PNG:` path you can view, and either a
```` ```mermaid ```` block (the source the canvas was drawn from) or a
```` ```text ```` summary of what is on it. Treat the summary's `#id` prefixes
as element ids for `blueprint_update`; treat a `sketch:` line as the user's
freehand annotation near the named element.

## Do not

- Redraw on every edit, or draw when nothing about the design changed.
- Replace a canvas the user sketched on without saying so.
- Put secrets, tokens, or private data in a diagram; the canvas persists per
  terminal and exports to disk.
