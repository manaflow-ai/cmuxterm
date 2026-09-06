import type { BlueprintElement } from "./elementModel";
import { boundsOf } from "./elementModel";
import { elementsToMermaid } from "./mermaidExport";
import { countLiveElements, liveElements, sceneDigest } from "./sceneDigest";
import { summarizeElements } from "./summary";

/**
 * The bridge between the Excalidraw canvas and the Swift host.
 *
 * Swift calls the functions installed on `window.cmuxBlueprint` through
 * `callAsyncJavaScript`; the bridge answers with JSON-serializable values and
 * pushes unsolicited events (user edits, export results) through the
 * `cmuxBlueprint` script message handler. Swift owns the revision counter; the
 * page only reports content digests so echoes of scenes it applied itself are
 * never reported back as user edits.
 *
 * Every Excalidraw runtime dependency arrives through `BlueprintBridgeDeps` so
 * the bridge is testable with plain objects.
 */

export type BlueprintSceneSource = "agent" | "restore" | "cli";
export type BlueprintTheme = "light" | "dark";

export type BlueprintOp =
  | { op: "upsert"; element: BlueprintSceneElement }
  | { op: "delete"; id: string }
  | { op: "clear" };

/** An Excalidraw element as carried across the bridge; opaque beyond the structural subset. */
export type BlueprintSceneElement = BlueprintElement & Record<string, unknown>;

export interface BlueprintSceneFile {
  id: string;
  [key: string]: unknown;
}

export interface BlueprintAppState {
  theme?: BlueprintTheme;
  viewBackgroundColor?: string;
  selectedElementIds?: Record<string, boolean>;
  activeTool?: { type: string };
  editingTextElement?: unknown;
  [key: string]: unknown;
}

/** The slice of `ExcalidrawImperativeAPI` the bridge drives. */
export interface BlueprintCanvasApi {
  getSceneElements(): readonly BlueprintSceneElement[];
  getSceneElementsIncludingDeleted(): readonly BlueprintSceneElement[];
  getAppState(): BlueprintAppState;
  getFiles(): Record<string, BlueprintSceneFile>;
  updateScene(scene: {
    elements?: readonly BlueprintSceneElement[];
    appState?: Partial<BlueprintAppState>;
    captureUpdate?: unknown;
  }): void;
  addFiles(files: BlueprintSceneFile[]): void;
  scrollToContent(target?: unknown, opts?: { fitToContent?: boolean; animate?: boolean }): void;
  history: { clear(): void };
}

export interface BlueprintExportRequest {
  elements: readonly BlueprintSceneElement[];
  appState: Partial<BlueprintAppState>;
  files: Record<string, BlueprintSceneFile> | null;
  dark: boolean;
  scale: number;
}

export interface BlueprintBridgeDeps {
  serializeScene(
    elements: readonly BlueprintSceneElement[],
    appState: Partial<BlueprintAppState>,
    files: Record<string, BlueprintSceneFile>,
  ): string;
  convertSkeleton(skeleton: readonly unknown[], opts: { regenerateIds: boolean }): BlueprintSceneElement[];
  restoreElements(elements: readonly unknown[]): BlueprintSceneElement[];
  parseMermaid(source: string): Promise<{ elements: unknown[]; files?: Record<string, BlueprintSceneFile> }>;
  exportPng(request: BlueprintExportRequest): Promise<string>;
  exportSvg(request: BlueprintExportRequest): Promise<string>;
  postMessage(message: BlueprintOutboundMessage): void;
  /** The scene-capture marker Excalidraw expects for host-applied updates (`CaptureUpdateAction.IMMEDIATELY`). */
  captureUpdate?: unknown;
  debounceMs?: number;
  now?: () => number;
}

export type BlueprintOutboundMessage =
  | { type: "ready" }
  | { type: "sceneChanged"; sceneJSON: string; elementCount: number; digest: string }
  | {
      type: "exportResult";
      requestId: string;
      pngBase64?: string;
      svg?: string;
      mermaid?: string;
      sceneJSON: string;
      width: number;
      height: number;
    }
  | { type: "exportFailed"; requestId: string; message: string }
  | { type: "requestTerminalFocus" }
  | { type: "error"; message: string };

export interface BlueprintUIHandlers {
  setTheme(theme: BlueprintTheme): void;
  setViewMode(enabled: boolean): void;
}

export interface BlueprintHostApi {
  setScene(sceneJSON: string, opts?: { source?: BlueprintSceneSource }): Promise<{ elementCount: number }>;
  getScene(): Promise<{ sceneJSON: string; elementCount: number }>;
  getSummary(): Promise<string>;
  getMermaid(): Promise<string | null>;
  renderMermaid(
    source: string,
    opts?: { mode?: "replace" | "append"; title?: string },
  ): Promise<{ elementCount: number; warnings: string[] }>;
  applyOps(ops: BlueprintOp[], opts?: { source?: BlueprintSceneSource }): Promise<{ applied: number }>;
  requestExport(
    requestId: string,
    opts?: { png?: boolean; svg?: boolean; mermaid?: boolean; scale?: number; dark?: boolean },
  ): Promise<void>;
  setTheme(theme: BlueprintTheme): Promise<void>;
  setViewMode(enabled: boolean): Promise<void>;
  zoomToFit(): Promise<void>;
  clear(): Promise<void>;
}

const APPEND_GAP = 48;
/** Excalidraw may re-normalize host-applied elements on its next tick; edits inside this window after an apply are treated as echoes. */
const APPLY_ECHO_WINDOW_MS = 150;

function errorMessage(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }
  return String(error);
}

export class BlueprintBridge {
  private api: BlueprintCanvasApi | null = null;
  private uiHandlers: BlueprintUIHandlers | null = null;
  private lastAppliedDigest: string | null = null;
  private lastAppliedAt = Number.NEGATIVE_INFINITY;
  private lastPostedDigest: string | null = null;
  private pendingChange: ReturnType<typeof setTimeout> | null = null;
  private lastMermaidSource: string | null = null;
  private readonly debounceMs: number;
  private readonly now: () => number;

  constructor(private readonly deps: BlueprintBridgeDeps) {
    this.debounceMs = deps.debounceMs ?? 400;
    this.now = deps.now ?? (() => Date.now());
  }

  /** Called once Excalidraw hands over its imperative API. */
  attach(api: BlueprintCanvasApi | null): void {
    if (!api || this.api === api) {
      return;
    }
    this.api = api;
    this.lastAppliedDigest = sceneDigest(api.getSceneElements());
    this.deps.postMessage({ type: "ready" });
  }

  setUIHandlers(handlers: BlueprintUIHandlers | null): void {
    this.uiHandlers = handlers;
  }

  /** Excalidraw `onChange`: reports user edits, debounced, skipping host-applied echoes. */
  handleChange(elements: readonly BlueprintSceneElement[]): void {
    const digest = sceneDigest(elements);
    if (digest === this.lastAppliedDigest || digest === this.lastPostedDigest) {
      return;
    }
    if (this.now() - this.lastAppliedAt < APPLY_ECHO_WINDOW_MS) {
      // Excalidraw settling a host-applied scene (bound text re-measure, version bumps).
      this.lastAppliedDigest = digest;
      return;
    }
    if (this.pendingChange) {
      clearTimeout(this.pendingChange);
    }
    this.pendingChange = setTimeout(() => {
      this.pendingChange = null;
      this.flushChange();
    }, this.debounceMs);
  }

  /** Escape with nothing selected and the selection tool active hands focus back to the terminal. */
  handleEscape(): boolean {
    const api = this.api;
    if (!api) {
      return false;
    }
    const state = api.getAppState();
    const selected = Object.keys(state.selectedElementIds ?? {}).length;
    const toolType = state.activeTool?.type ?? "selection";
    if (selected > 0 || toolType !== "selection" || state.editingTextElement) {
      return false;
    }
    this.deps.postMessage({ type: "requestTerminalFocus" });
    return true;
  }

  hostApi(): BlueprintHostApi {
    return {
      setScene: (sceneJSON, opts) => this.guard(() => this.setScene(sceneJSON, opts?.source ?? "agent")),
      getScene: () => this.guard(() => this.getScene()),
      getSummary: () => this.guard(() => summarizeElements(this.requireApi().getSceneElements())),
      getMermaid: () => this.guard(() => this.lastMermaidSource),
      renderMermaid: (source, opts) => this.guard(() => this.renderMermaid(source, opts?.mode ?? "replace")),
      applyOps: (ops) => this.guard(() => this.applyOps(ops)),
      requestExport: (requestId, opts) => this.guard(() => this.requestExport(requestId, opts ?? {})),
      setTheme: (theme) => this.guard(() => {
        this.uiHandlers?.setTheme(theme);
        this.api?.updateScene({ appState: { theme } });
      }),
      setViewMode: (enabled) => this.guard(() => {
        this.uiHandlers?.setViewMode(enabled);
      }),
      zoomToFit: () => this.guard(() => {
        this.requireApi().scrollToContent(undefined, { fitToContent: true, animate: false });
      }),
      clear: () => this.guard(() => {
        this.replaceElements([], null);
        this.lastMermaidSource = null;
      }),
    };
  }

  private async guard<T>(body: () => T | Promise<T>): Promise<T> {
    try {
      return await body();
    } catch (error) {
      this.deps.postMessage({ type: "error", message: errorMessage(error) });
      throw error;
    }
  }

  private requireApi(): BlueprintCanvasApi {
    if (!this.api) {
      throw new Error("Blueprint canvas is not ready");
    }
    return this.api;
  }

  private flushChange(): void {
    const api = this.api;
    if (!api) {
      return;
    }
    const elements = api.getSceneElements();
    const digest = sceneDigest(elements);
    if (digest === this.lastAppliedDigest || digest === this.lastPostedDigest) {
      return;
    }
    this.lastPostedDigest = digest;
    this.deps.postMessage({
      type: "sceneChanged",
      sceneJSON: this.serialize(elements),
      elementCount: countLiveElements(elements),
      digest,
    });
  }

  private serialize(elements: readonly BlueprintSceneElement[]): string {
    const api = this.requireApi();
    return this.deps.serializeScene(liveElements(elements), api.getAppState(), api.getFiles());
  }

  private replaceElements(
    elements: readonly BlueprintSceneElement[],
    files: Record<string, BlueprintSceneFile> | null | undefined,
  ): void {
    const api = this.requireApi();
    if (files && Object.keys(files).length > 0) {
      api.addFiles(Object.values(files));
    }
    api.updateScene({ elements, captureUpdate: this.deps.captureUpdate });
    this.markApplied(api);
  }

  private markApplied(api: BlueprintCanvasApi): void {
    this.lastAppliedDigest = sceneDigest(api.getSceneElements());
    this.lastAppliedAt = this.now();
    if (this.pendingChange) {
      clearTimeout(this.pendingChange);
      this.pendingChange = null;
    }
  }

  private setScene(sceneJSON: string, source: BlueprintSceneSource): { elementCount: number } {
    const parsed: unknown = JSON.parse(sceneJSON);
    if (!parsed || typeof parsed !== "object") {
      throw new Error("Scene must be a JSON object");
    }
    const scene = parsed as {
      elements?: unknown[];
      skeleton?: unknown[];
      appState?: Partial<BlueprintAppState>;
      files?: Record<string, BlueprintSceneFile>;
    };
    let elements: BlueprintSceneElement[];
    if (Array.isArray(scene.skeleton)) {
      elements = this.deps.convertSkeleton(scene.skeleton, { regenerateIds: false });
    } else if (Array.isArray(scene.elements)) {
      elements = this.deps.restoreElements(scene.elements);
    } else {
      throw new Error("Scene needs an `elements` or `skeleton` array");
    }
    this.replaceElements(elements, scene.files);
    if (source !== "restore") {
      this.lastMermaidSource = null;
    }
    if (scene.appState?.viewBackgroundColor) {
      this.requireApi().updateScene({ appState: { viewBackgroundColor: scene.appState.viewBackgroundColor } });
    }
    return { elementCount: countLiveElements(elements) };
  }

  private getScene(): { sceneJSON: string; elementCount: number } {
    const elements = this.requireApi().getSceneElements();
    return { sceneJSON: this.serialize(elements), elementCount: countLiveElements(elements) };
  }

  private async renderMermaid(
    source: string,
    mode: "replace" | "append",
  ): Promise<{ elementCount: number; warnings: string[] }> {
    const api = this.requireApi();
    const warnings: string[] = [];
    const parsed = await this.deps.parseMermaid(source);
    const fresh = this.deps.convertSkeleton(parsed.elements, { regenerateIds: mode === "append" });
    let next: BlueprintSceneElement[];
    if (mode === "append") {
      const existing = liveElements(api.getSceneElements());
      const existingBounds = boundsOf(existing);
      const freshBounds = boundsOf(fresh);
      if (existingBounds && freshBounds) {
        const dx = existingBounds.minX - freshBounds.minX;
        const dy = existingBounds.maxY + APPEND_GAP - freshBounds.minY;
        for (const element of fresh) {
          element.x += dx;
          element.y += dy;
        }
      }
      next = [...existing, ...fresh];
      this.lastMermaidSource = this.lastMermaidSource ? `${this.lastMermaidSource}\n\n${source}` : source;
    } else {
      next = fresh;
      this.lastMermaidSource = source;
    }
    if (fresh.length === 0) {
      warnings.push("The Mermaid diagram produced no elements");
    }
    this.replaceElements(next, parsed.files);
    api.scrollToContent(undefined, { fitToContent: true, animate: false });
    return { elementCount: countLiveElements(next), warnings };
  }

  private applyOps(ops: BlueprintOp[]): { applied: number } {
    const api = this.requireApi();
    let elements = [...liveElements(api.getSceneElements())];
    let applied = 0;
    for (const op of ops) {
      if (op.op === "clear") {
        elements = [];
        applied += 1;
      } else if (op.op === "delete") {
        const before = elements.length;
        elements = elements.filter((element) => element.id !== op.id);
        if (elements.length !== before) {
          applied += 1;
        }
      } else if (op.op === "upsert") {
        const [restored] = this.deps.restoreElements([op.element]);
        if (!restored) {
          continue;
        }
        const index = elements.findIndex((element) => element.id === restored.id);
        if (index >= 0) {
          elements[index] = restored;
        } else {
          elements.push(restored);
        }
        applied += 1;
      }
    }
    this.replaceElements(elements, null);
    return { applied };
  }

  private async requestExport(
    requestId: string,
    opts: { png?: boolean; svg?: boolean; mermaid?: boolean; scale?: number; dark?: boolean },
  ): Promise<void> {
    try {
      const api = this.requireApi();
      const elements = liveElements(api.getSceneElements());
      const bounds = boundsOf(elements);
      const request: BlueprintExportRequest = {
        elements,
        appState: api.getAppState(),
        files: api.getFiles(),
        dark: opts.dark ?? api.getAppState().theme === "dark",
        scale: opts.scale ?? 2,
      };
      const [pngBase64, svg] = await Promise.all([
        opts.png ? this.deps.exportPng(request) : Promise.resolve(undefined),
        opts.svg ? this.deps.exportSvg(request) : Promise.resolve(undefined),
      ]);
      this.deps.postMessage({
        type: "exportResult",
        requestId,
        pngBase64,
        svg,
        mermaid: opts.mermaid ? elementsToMermaid(elements) : undefined,
        sceneJSON: this.serialize(elements),
        width: bounds ? Math.round(bounds.maxX - bounds.minX) : 0,
        height: bounds ? Math.round(bounds.maxY - bounds.minY) : 0,
      });
    } catch (error) {
      this.deps.postMessage({ type: "exportFailed", requestId, message: errorMessage(error) });
    }
  }
}

interface BlueprintHostWindow {
  cmuxBlueprint?: BlueprintHostApi;
  webkit?: {
    messageHandlers?: {
      cmuxBlueprint?: { postMessage(message: unknown): void };
    };
  };
}

/** Posts to the Swift `cmuxBlueprint` handler, or drops the message outside WebKit. */
export function postToHost(message: BlueprintOutboundMessage): void {
  const host = globalThis as unknown as BlueprintHostWindow;
  host.webkit?.messageHandlers?.cmuxBlueprint?.postMessage(message);
}

export function installBlueprintBridge(bridge: BlueprintBridge): void {
  const host = globalThis as unknown as BlueprintHostWindow;
  host.cmuxBlueprint = bridge.hostApi();
}
