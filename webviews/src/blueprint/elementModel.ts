/**
 * The structural subset of an Excalidraw element the pure blueprint helpers
 * (summary, Mermaid export) read. Kept loose so tests and the bridge can pass
 * plain objects without importing Excalidraw's element types at runtime.
 */
export interface BlueprintElement {
  id: string;
  type: string;
  x: number;
  y: number;
  width: number;
  height: number;
  isDeleted?: boolean;
  version?: number;
  text?: string;
  containerId?: string | null;
  boundElements?: readonly { id: string; type: string }[] | null;
  startBinding?: { elementId: string } | null;
  endBinding?: { elementId: string } | null;
  points?: readonly (readonly number[])[];
}

export const SHAPE_TYPES: ReadonlySet<string> = new Set([
  "rectangle",
  "diamond",
  "ellipse",
  "image",
  "frame",
  "magicframe",
  "embeddable",
  "iframe",
]);

export const CONNECTOR_TYPES: ReadonlySet<string> = new Set(["arrow", "line"]);

export function shortId(id: string): string {
  return id.length <= 8 ? id : id.slice(0, 8);
}

export function truncateLabel(text: string, maxLength = 60): string {
  const collapsed = text.replace(/\s+/g, " ").trim();
  if (collapsed.length <= maxLength) {
    return collapsed;
  }
  return `${collapsed.slice(0, maxLength - 1)}…`;
}

/** Text elements keyed by the container they are bound to. */
export function boundTextByContainer(elements: readonly BlueprintElement[]): Map<string, BlueprintElement> {
  const byContainer = new Map<string, BlueprintElement>();
  for (const element of elements) {
    if (element.isDeleted || element.type !== "text" || !element.containerId) {
      continue;
    }
    if (!byContainer.has(element.containerId)) {
      byContainer.set(element.containerId, element);
    }
  }
  return byContainer;
}

/** The label of a shape or connector: its bound text, or its own text for text elements. */
export function elementLabel(
  element: BlueprintElement,
  boundText: Map<string, BlueprintElement>,
): string {
  const bound = boundText.get(element.id);
  if (bound?.text) {
    return bound.text;
  }
  if (typeof element.text === "string") {
    return element.text;
  }
  return "";
}

export function boundsOf(elements: readonly BlueprintElement[]): { minX: number; minY: number; maxX: number; maxY: number } | null {
  let minX = Number.POSITIVE_INFINITY;
  let minY = Number.POSITIVE_INFINITY;
  let maxX = Number.NEGATIVE_INFINITY;
  let maxY = Number.NEGATIVE_INFINITY;
  let any = false;
  for (const element of elements) {
    if (element.isDeleted) {
      continue;
    }
    any = true;
    minX = Math.min(minX, element.x);
    minY = Math.min(minY, element.y);
    maxX = Math.max(maxX, element.x + Math.max(0, element.width));
    maxY = Math.max(maxY, element.y + Math.max(0, element.height));
  }
  return any ? { minX, minY, maxX, maxY } : null;
}

/** Deterministic reading order: top to bottom, then left to right. */
export function sortByPosition<T extends BlueprintElement>(elements: readonly T[]): T[] {
  return [...elements].sort((a, b) => {
    if (Math.round(a.y) !== Math.round(b.y)) {
      return a.y - b.y;
    }
    if (Math.round(a.x) !== Math.round(b.x)) {
      return a.x - b.x;
    }
    return a.id.localeCompare(b.id);
  });
}
