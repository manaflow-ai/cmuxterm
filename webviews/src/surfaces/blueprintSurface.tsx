import excalidrawStyles from "@excalidraw/excalidraw/index.css?inline";
import { createRoot } from "react-dom/client";
import { BlueprintApp, initialThemeFromLocation } from "../blueprint/BlueprintApp";
import { installWebviewStyles } from "./installWebviewStyles";

const surfaceStyles = `
html, body, #root, .cmux-blueprint-root {
  margin: 0;
  padding: 0;
  width: 100%;
  height: 100%;
  background: transparent;
  overflow: hidden;
}
.cmux-blueprint-root {
  position: absolute;
  inset: 0;
}
.cmux-blueprint-root .excalidraw {
  --color-primary: #6965db;
}
`;

/**
 * Boots the blueprint surface: an Excalidraw canvas bound to a terminal pane,
 * driven by Swift through `window.cmuxBlueprint`. Loaded as its own chunk so
 * the diff viewer and agent session never ship the canvas.
 */
export function mountBlueprintSurface(rootElement: HTMLElement): void {
  installWebviewStyles("blueprint-excalidraw", excalidrawStyles);
  installWebviewStyles("blueprint", surfaceStyles);
  document.documentElement.dataset.cmuxWebviewKind = "blueprint";
  document.body.dataset.cmuxWebviewKind = "blueprint";
  const initialTheme = initialThemeFromLocation(window.location.search);
  document.documentElement.style.colorScheme = initialTheme;
  createRoot(rootElement).render(<BlueprintApp initialTheme={initialTheme} />);
}
