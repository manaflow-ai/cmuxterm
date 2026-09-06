import { exportToBlob, exportToSvg } from "@excalidraw/excalidraw";
import type { ExcalidrawElement, NonDeleted } from "@excalidraw/excalidraw/element/types";
import type { AppState, BinaryFiles } from "@excalidraw/excalidraw/types";

export interface ExportSceneInput {
  elements: readonly NonDeleted<ExcalidrawElement>[];
  appState: Partial<AppState>;
  files: BinaryFiles | null;
  dark: boolean;
  scale: number;
}

const LIGHT_BACKGROUND = "#ffffff";
const DARK_BACKGROUND = "#121212";

function exportAppState(input: ExportSceneInput): Partial<AppState> {
  return {
    ...input.appState,
    exportBackground: true,
    exportWithDarkMode: input.dark,
    viewBackgroundColor: input.dark ? DARK_BACKGROUND : LIGHT_BACKGROUND,
  };
}

function blobToBase64(blob: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onerror = () => reject(reader.error ?? new Error("Could not read exported image"));
    reader.onload = () => {
      const result = typeof reader.result === "string" ? reader.result : "";
      const comma = result.indexOf(",");
      resolve(comma >= 0 ? result.slice(comma + 1) : result);
    };
    reader.readAsDataURL(blob);
  });
}

/** Renders the scene to a PNG and returns its base64 payload (no data: prefix). */
export async function exportScenePngBase64(input: ExportSceneInput): Promise<string> {
  const blob = await exportToBlob({
    elements: input.elements,
    appState: exportAppState(input),
    files: input.files,
    mimeType: "image/png",
    getDimensions: (width, height) => ({ width, height, scale: input.scale }),
  });
  return blobToBase64(blob);
}

/** Renders the scene to standalone SVG markup. */
export async function exportSceneSvg(input: ExportSceneInput): Promise<string> {
  const svg = await exportToSvg({
    elements: input.elements,
    appState: exportAppState(input),
    files: input.files,
  });
  return svg.outerHTML;
}
