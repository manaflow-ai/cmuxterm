import { CaptureUpdateAction, convertToExcalidrawElements, Excalidraw, restoreElements, serializeAsJSON } from "@excalidraw/excalidraw";
import type { ExcalidrawElement, NonDeleted } from "@excalidraw/excalidraw/element/types";
import type { AppState, BinaryFiles, ExcalidrawImperativeAPI } from "@excalidraw/excalidraw/types";
import { useEffect, useMemo, useState } from "react";
import {
  BlueprintBridge,
  type BlueprintBridgeDeps,
  type BlueprintCanvasApi,
  type BlueprintSceneElement,
  type BlueprintSceneFile,
  type BlueprintTheme,
  installBlueprintBridge,
  postToHost,
} from "./bridge";
import { exportScenePngBase64, exportSceneSvg } from "./exportScene";

export function initialThemeFromLocation(search: string): BlueprintTheme {
  const params = new URLSearchParams(search);
  return params.get("theme") === "dark" ? "dark" : "light";
}

function makeBridgeDeps(): BlueprintBridgeDeps {
  return {
    serializeScene: (elements, appState, files) =>
      serializeAsJSON(
        elements as unknown as readonly ExcalidrawElement[],
        appState as Partial<AppState>,
        files as unknown as BinaryFiles,
        "local",
      ),
    convertSkeleton: (skeleton, opts) =>
      convertToExcalidrawElements(skeleton as Parameters<typeof convertToExcalidrawElements>[0], opts) as unknown as BlueprintSceneElement[],
    restoreElements: (elements) =>
      restoreElements(elements as readonly ExcalidrawElement[], null) as unknown as BlueprintSceneElement[],
    parseMermaid: async (source) => {
      const { parseMermaidToExcalidraw } = await import("@excalidraw/mermaid-to-excalidraw");
      const result = await parseMermaidToExcalidraw(source);
      return {
        elements: result.elements,
        files: result.files as unknown as Record<string, BlueprintSceneFile> | undefined,
      };
    },
    exportPng: (request) =>
      exportScenePngBase64({
        elements: request.elements as unknown as readonly NonDeleted<ExcalidrawElement>[],
        appState: request.appState as Partial<AppState>,
        files: request.files as unknown as BinaryFiles | null,
        dark: request.dark,
        scale: request.scale,
      }),
    exportSvg: (request) =>
      exportSceneSvg({
        elements: request.elements as unknown as readonly NonDeleted<ExcalidrawElement>[],
        appState: request.appState as Partial<AppState>,
        files: request.files as unknown as BinaryFiles | null,
        dark: request.dark,
        scale: request.scale,
      }),
    postMessage: postToHost,
    captureUpdate: CaptureUpdateAction.IMMEDIATELY,
  };
}

export function BlueprintApp({ initialTheme }: { initialTheme: BlueprintTheme }) {
  const bridge = useMemo(() => new BlueprintBridge(makeBridgeDeps()), []);
  const [theme, setTheme] = useState<BlueprintTheme>(initialTheme);
  const [viewMode, setViewMode] = useState(false);

  useEffect(() => {
    bridge.setUIHandlers({ setTheme, setViewMode });
    installBlueprintBridge(bridge);
    return () => bridge.setUIHandlers(null);
  }, [bridge]);

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key !== "Escape") {
        return;
      }
      if (bridge.handleEscape()) {
        event.preventDefault();
        event.stopPropagation();
      }
    };
    window.addEventListener("keydown", onKeyDown, true);
    return () => window.removeEventListener("keydown", onKeyDown, true);
  }, [bridge]);

  return (
    <div className="cmux-blueprint-root">
      <Excalidraw
        excalidrawAPI={(api: ExcalidrawImperativeAPI) => bridge.attach(api as unknown as BlueprintCanvasApi)}
        theme={theme}
        viewModeEnabled={viewMode}
        initialData={{ appState: { viewBackgroundColor: "transparent" } }}
        onChange={(elements) => bridge.handleChange(elements as unknown as readonly BlueprintSceneElement[])}
        UIOptions={{
          canvasActions: {
            loadScene: false,
            saveToActiveFile: false,
            export: false,
            saveAsImage: false,
            toggleTheme: false,
          },
        }}
      />
    </div>
  );
}
