import { afterEach, describe, expect, test } from "bun:test";
import {
  BlueprintBridge,
  type BlueprintBridgeDeps,
  type BlueprintCanvasApi,
  type BlueprintOutboundMessage,
  type BlueprintSceneElement,
  installBlueprintBridge,
  postToHost,
} from "../src/blueprint/bridge";

function element(id: string, version: number, extra: Partial<BlueprintSceneElement> = {}): BlueprintSceneElement {
  return { id, type: "rectangle", x: 0, y: 0, width: 100, height: 50, version, ...extra };
}

class FakeCanvasApi implements BlueprintCanvasApi {
  elements: BlueprintSceneElement[] = [];
  files: Record<string, { id: string }> = {};
  appState: Record<string, unknown> = { theme: "light", selectedElementIds: {}, activeTool: { type: "selection" } };
  scrolls = 0;
  history = { clear: () => {} };

  getSceneElements() {
    return this.elements.filter((candidate) => !candidate.isDeleted);
  }
  getSceneElementsIncludingDeleted() {
    return this.elements;
  }
  getAppState() {
    return this.appState;
  }
  getFiles() {
    return this.files;
  }
  updateScene(scene: { elements?: readonly BlueprintSceneElement[]; appState?: Record<string, unknown> }) {
    if (scene.elements) {
      this.elements = [...scene.elements];
    }
    if (scene.appState) {
      this.appState = { ...this.appState, ...scene.appState };
    }
  }
  addFiles(files: { id: string }[]) {
    for (const file of files) {
      this.files[file.id] = file;
    }
  }
  scrollToContent() {
    this.scrolls += 1;
  }
}

function makeBridge(overrides: Partial<BlueprintBridgeDeps> = {}) {
  const messages: BlueprintOutboundMessage[] = [];
  let now = 1_000_000;
  const deps: BlueprintBridgeDeps = {
    serializeScene: (elements) => JSON.stringify({ elements }),
    convertSkeleton: (skeleton) => skeleton.map((item, index) => element(`sk${index}`, 1, item as Partial<BlueprintSceneElement>)),
    restoreElements: (elements) => elements.map((item) => ({ ...(item as BlueprintSceneElement) })),
    parseMermaid: async () => ({ elements: [{ x: 0, y: 0 }, { x: 0, y: 100 }] }),
    exportPng: async () => "cG5n",
    exportSvg: async () => "<svg/>",
    postMessage: (message) => {
      messages.push(message);
    },
    debounceMs: 5,
    now: () => now,
    ...overrides,
  };
  const bridge = new BlueprintBridge(deps);
  const api = new FakeCanvasApi();
  return {
    bridge,
    api,
    messages,
    advance(ms: number) {
      now += ms;
    },
  };
}

function wait(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

const originalGlobals = new Map<string, unknown>();
for (const key of ["cmuxBlueprint", "webkit"]) {
  originalGlobals.set(key, (globalThis as Record<string, unknown>)[key]);
}

afterEach(() => {
  for (const [key, value] of originalGlobals) {
    if (value === undefined) {
      delete (globalThis as Record<string, unknown>)[key];
    } else {
      (globalThis as Record<string, unknown>)[key] = value;
    }
  }
});

describe("BlueprintBridge", () => {
  test("posts ready once the canvas API attaches", () => {
    const { bridge, api, messages } = makeBridge();
    bridge.attach(api);
    bridge.attach(api);
    expect(messages).toEqual([{ type: "ready" }]);
  });

  test("setScene applies elements and suppresses the echoed onChange", async () => {
    const { bridge, api, messages, advance } = makeBridge();
    bridge.attach(api);
    const result = await bridge.hostApi().setScene(JSON.stringify({ elements: [element("a", 1), element("b", 2)] }));
    expect(result).toEqual({ elementCount: 2 });
    expect(api.getSceneElements().map((candidate) => candidate.id)).toEqual(["a", "b"]);

    bridge.handleChange(api.getSceneElements());
    advance(1000);
    bridge.handleChange(api.getSceneElements());
    await wait(20);
    expect(messages.filter((message) => message.type === "sceneChanged")).toHaveLength(0);
  });

  test("a user edit posts one debounced sceneChanged with the live count and digest", async () => {
    const { bridge, api, messages, advance } = makeBridge();
    bridge.attach(api);
    await bridge.hostApi().setScene(JSON.stringify({ elements: [element("a", 1)] }));
    advance(1000);

    api.elements = [element("a", 2), element("gone", 1, { isDeleted: true })];
    bridge.handleChange(api.elements);
    bridge.handleChange(api.elements);
    bridge.handleChange(api.elements);
    await wait(20);

    const changes = messages.filter((message) => message.type === "sceneChanged");
    expect(changes).toHaveLength(1);
    const change = changes[0];
    if (change?.type !== "sceneChanged") {
      throw new Error("expected sceneChanged");
    }
    expect(change.elementCount).toBe(1);
    expect(change.digest.startsWith("1-")).toBe(true);
    expect(JSON.parse(change.sceneJSON).elements.map((candidate: { id: string }) => candidate.id)).toEqual(["a"]);

    bridge.handleChange(api.elements);
    await wait(20);
    expect(messages.filter((message) => message.type === "sceneChanged")).toHaveLength(1);
  });

  test("getSummary and getScene read the live scene", async () => {
    const { bridge, api } = makeBridge();
    bridge.attach(api);
    api.elements = [
      element("box", 1),
      { id: "t", type: "text", x: 0, y: 0, width: 1, height: 1, version: 1, text: "Queue", containerId: "box" },
    ];
    expect(await bridge.hostApi().getSummary()).toBe('#box rectangle "Queue" (0,0 100x50)');
    const scene = await bridge.hostApi().getScene();
    expect(scene.elementCount).toBe(2);
    expect(JSON.parse(scene.sceneJSON).elements).toHaveLength(2);
  });

  test("renderMermaid replaces or appends below the existing scene and remembers the source", async () => {
    const { bridge, api } = makeBridge();
    bridge.attach(api);
    const host = bridge.hostApi();
    const first = await host.renderMermaid("flowchart LR; A-->B", { mode: "replace" });
    expect(first).toEqual({ elementCount: 2, warnings: [] });
    expect(await host.getMermaid()).toBe("flowchart LR; A-->B");
    expect(api.scrolls).toBe(1);

    const second = await host.renderMermaid("flowchart LR; C-->D", { mode: "append" });
    expect(second.elementCount).toBe(4);
    const ys = api.getSceneElements().map((candidate) => candidate.y);
    // Existing scene spans y 0..150; appended elements start 48px below it.
    expect(ys.slice(2)).toEqual([198, 298]);
    expect(await host.getMermaid()).toBe("flowchart LR; A-->B\n\nflowchart LR; C-->D");

    await host.setScene(JSON.stringify({ elements: [] }));
    expect(await host.getMermaid()).toBeNull();
  });

  test("applyOps upserts, deletes, and clears", async () => {
    const { bridge, api } = makeBridge();
    bridge.attach(api);
    api.elements = [element("a", 1), element("b", 1)];
    const host = bridge.hostApi();
    expect(
      await host.applyOps([
        { op: "upsert", element: element("a", 5, { width: 10 }) },
        { op: "upsert", element: element("c", 1) },
        { op: "delete", id: "b" },
        { op: "delete", id: "missing" },
      ]),
    ).toEqual({ applied: 3 });
    expect(api.getSceneElements().map((candidate) => [candidate.id, candidate.width])).toEqual([
      ["a", 10],
      ["c", 100],
    ]);
    expect(await host.applyOps([{ op: "clear" }])).toEqual({ applied: 1 });
    expect(api.getSceneElements()).toHaveLength(0);
  });

  test("requestExport posts the requested formats and dimensions", async () => {
    const { bridge, api, messages } = makeBridge();
    bridge.attach(api);
    api.elements = [element("a", 1), element("b", 1, { x: 200, y: 100 })];
    await bridge.hostApi().requestExport("req-1", { png: true, mermaid: true });
    const result = messages.find((message) => message.type === "exportResult");
    if (result?.type !== "exportResult") {
      throw new Error("expected exportResult");
    }
    expect(result.requestId).toBe("req-1");
    expect(result.pngBase64).toBe("cG5n");
    expect(result.svg).toBeUndefined();
    expect(result.mermaid?.startsWith("flowchart LR")).toBe(true);
    expect(result.width).toBe(300);
    expect(result.height).toBe(150);
  });

  test("requestExport failure posts exportFailed instead of throwing", async () => {
    const { bridge, api, messages } = makeBridge({
      exportPng: async () => {
        throw new Error("canvas too large");
      },
    });
    bridge.attach(api);
    await bridge.hostApi().requestExport("req-2", { png: true });
    expect(messages.at(-1)).toEqual({ type: "exportFailed", requestId: "req-2", message: "canvas too large" });
  });

  test("calls before the canvas is ready post an error and reject", async () => {
    const { bridge, messages } = makeBridge();
    await expect(bridge.hostApi().getScene()).rejects.toThrow("not ready");
    expect(messages.at(-1)).toEqual({ type: "error", message: "Blueprint canvas is not ready" });
  });

  test("escape hands focus back only when nothing is selected and the selection tool is active", () => {
    const { bridge, api, messages } = makeBridge();
    bridge.attach(api);
    api.appState = { ...api.appState, selectedElementIds: { a: true } };
    expect(bridge.handleEscape()).toBe(false);
    api.appState = { ...api.appState, selectedElementIds: {}, activeTool: { type: "rectangle" } };
    expect(bridge.handleEscape()).toBe(false);
    api.appState = { ...api.appState, activeTool: { type: "selection" } };
    expect(bridge.handleEscape()).toBe(true);
    expect(messages.at(-1)).toEqual({ type: "requestTerminalFocus" });
  });

  test("setTheme and setViewMode reach the UI handlers", async () => {
    const { bridge, api } = makeBridge();
    bridge.attach(api);
    const calls: string[] = [];
    bridge.setUIHandlers({
      setTheme: (theme) => calls.push(`theme:${theme}`),
      setViewMode: (enabled) => calls.push(`view:${enabled}`),
    });
    await bridge.hostApi().setTheme("dark");
    await bridge.hostApi().setViewMode(true);
    expect(calls).toEqual(["theme:dark", "view:true"]);
    expect(api.appState.theme).toBe("dark");
  });

  test("installBlueprintBridge exposes window.cmuxBlueprint and postToHost reaches the WebKit handler", () => {
    const posted: unknown[] = [];
    (globalThis as Record<string, unknown>).webkit = {
      messageHandlers: { cmuxBlueprint: { postMessage: (message: unknown) => posted.push(message) } },
    };
    const { bridge } = makeBridge();
    installBlueprintBridge(bridge);
    expect(typeof (globalThis as Record<string, unknown>).cmuxBlueprint).toBe("object");
    postToHost({ type: "ready" });
    expect(posted).toEqual([{ type: "ready" }]);
  });
});
