type WebviewKind = "agent-session" | "blueprint" | "diff";

function resolveWebviewKind(): WebviewKind {
  if (
    document.documentElement.dataset.cmuxWebviewKind === "agent-session" ||
    document.body.dataset.cmuxWebviewKind === "agent-session" ||
    document.getElementById("cmux-agent-session-config")
  ) {
    return "agent-session";
  }
  if (
    document.documentElement.dataset.cmuxWebviewKind === "blueprint" ||
    document.body.dataset.cmuxWebviewKind === "blueprint"
  ) {
    return "blueprint";
  }
  return "diff";
}

const rootElement = document.getElementById("root");
if (!rootElement) {
  throw new Error("Missing cmux webview root");
}

// Load only the active surface so each one ships as its own chunk: the diff
// viewer pulls in `@pierre/diffs`, the agent session pulls in its editor UI,
// and neither pays for the other. Shared vendor code (React, the router) is
// hoisted by Rollup into chunks both surfaces reuse.
const webviewKind = resolveWebviewKind();
if (webviewKind === "agent-session") {
  void import("./surfaces/agentSessionSurface").then((surface) => {
    surface.mountAgentSessionSurface(rootElement);
  });
} else if (webviewKind === "blueprint") {
  void import("./surfaces/blueprintSurface").then((surface) => {
    surface.mountBlueprintSurface(rootElement);
  });
} else {
  void import("./surfaces/diffSurface").then((surface) => {
    surface.mountDiffSurface(rootElement);
  });
}
