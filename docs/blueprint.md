# Blueprint: a diagram canvas for every terminal

Blueprint gives each terminal pane its own Excalidraw canvas, docked below the
terminal. It is the visual counterpart of the voice agent: the agent running in
that terminal (Claude Code, Codex) can draw the design it is working on, and you
can sketch on the same canvas and send the result back into the prompt.

Status: beta. Phase 1 ships the per-terminal drawer, persistence, and every
entrypoint. The agent-facing socket methods, CLI, Mermaid round trip,
"Send to terminal", and the `cmux-blueprint` MCP server follow in later phases.

## Enable it

Settings › Beta Features › **Blueprint**. While the toggle is off, the drawer,
its commands, the tab-bar button, and the shortcut are hidden.

The setting is `blueprint.beta.enabled` in `~/.config/cmux/cmux.json`.
`blueprint.autoOpenOnAgentUpdate` (default `true`) controls whether an agent
update opens a closed drawer or only marks it as updated.

## Open, collapse, enlarge

Every entrypoint goes through one shared action path
(`TabManager.performBlueprintAction`), so they behave identically:

| Entrypoint | How |
|---|---|
| Command palette | Toggle Blueprint, Collapse or Expand Blueprint, Enlarge or Restore Blueprint |
| View menu | Toggle Blueprint |
| Keyboard shortcut | `toggleTerminalBlueprint` (unbound by default; bind it in Settings › Shortcuts or `cmux.json`) |
| Surface tab bar | the `cmux.toggleBlueprint` built-in button (add it to `surfaceTabBar.buttons` in `cmux.json`) |
| Drawer header | chevron collapses to the header bar, the arrows enlarge or restore, the menu offers Zoom to Fit, Clear Canvas, Hide Blueprint |

The drawer takes a fraction of the pane (40% by default). Drag the divider on
its top edge to resize between 15% and 85%; the terminal always keeps at least
96 points. Double-click the header to collapse or expand. Press Escape on an
empty selection to hand keyboard focus back to the terminal.

## Where the drawing lives

Scenes are stored per terminal, keyed by the terminal's restart-stable surface
id, under `~/Library/Application Support/cmux/blueprints-<bundle id>/`. Tagged
dev builds therefore never overwrite the main app's blueprints. The session
snapshot only records whether the drawer is open, its layout, and the revision,
so the session file stays small; the scene is reloaded from the store on
restore.

Every accepted change bumps a revision counter, whoever authored it. Agents will
use that revision to notice that you edited the canvas since they last read it.

## How it is built

- The canvas is the bundled `webviews/` React app (`blueprint.html`), served to
  a `WKWebView` through the `cmux-blueprint://app/` custom scheme so the
  build-time deflated chunks can be inflated on the way in.
- `window.cmuxBlueprint` is the page contract (`setScene`, `getScene`,
  `getSummary`, `renderMermaid`, `applyOps`, `requestExport`, `setTheme`,
  `zoomToFit`, `clear`), and the page posts `ready`, `sceneChanged`,
  `exportResult`, `exportFailed`, `requestTerminalFocus`, and `error` to the
  `cmuxBlueprint` message handler.
- `TerminalBlueprintState` (owned by `TerminalPanel`) is the single source of
  truth for the drawer, the revision, and persistence.

## Privacy

Everything stays on this Mac. No scene, image, or text leaves the app unless a
later phase's "Send to terminal" puts it into your prompt, which you trigger.
