import {
  type BlueprintElement,
  boundTextByContainer,
  CONNECTOR_TYPES,
  elementLabel,
  shortId,
  sortByPosition,
  truncateLabel,
} from "./elementModel";

export const SUMMARY_LINE_CAP = 200;

function quoted(text: string): string {
  return `"${truncateLabel(text).replace(/"/g, "'")}"`;
}

function geometry(element: BlueprintElement): string {
  const x = Math.round(element.x);
  const y = Math.round(element.y);
  const width = Math.round(element.width);
  const height = Math.round(element.height);
  return `(${x},${y} ${width}x${height})`;
}

function centerDistance(a: BlueprintElement, b: BlueprintElement): number {
  const ax = a.x + a.width / 2;
  const ay = a.y + a.height / 2;
  const bx = b.x + b.width / 2;
  const by = b.y + b.height / 2;
  return Math.hypot(ax - bx, ay - by);
}

/**
 * Compact, LLM-friendly text rendering of a scene: one line per live element,
 * arrows expressed as edges, freehand strokes collapsed into a single line,
 * capped at `SUMMARY_LINE_CAP` lines.
 */
export function summarizeElements(elements: readonly BlueprintElement[]): string {
  const live = elements.filter((element) => !element.isDeleted);
  if (live.length === 0) {
    return "(empty blueprint)";
  }
  const boundText = boundTextByContainer(live);
  const byId = new Map(live.map((element) => [element.id, element] as const));
  const labeled = live.filter((element) => element.type !== "freedraw" && elementLabel(element, boundText).length > 0);

  const lines: string[] = [];
  const strokes: BlueprintElement[] = [];
  for (const element of sortByPosition(live)) {
    if (element.type === "freedraw") {
      strokes.push(element);
      continue;
    }
    if (element.type === "text" && element.containerId && byId.has(element.containerId)) {
      // Rendered as the container's label.
      continue;
    }
    const label = elementLabel(element, boundText);
    if (CONNECTOR_TYPES.has(element.type)) {
      const from = element.startBinding?.elementId;
      const to = element.endBinding?.elementId;
      const fromText = from && byId.has(from) ? `#${shortId(from)}` : "?";
      const toText = to && byId.has(to) ? `#${shortId(to)}` : "?";
      const labelText = label ? ` ${quoted(label)}` : "";
      lines.push(`#${shortId(element.id)} ${element.type} ${fromText} -> ${toText}${labelText}`);
      continue;
    }
    if (element.type === "text") {
      lines.push(`#${shortId(element.id)} text ${quoted(label)}`);
      continue;
    }
    lines.push(`#${shortId(element.id)} ${element.type} ${quoted(label)} ${geometry(element)}`);
  }

  if (strokes.length > 0) {
    let nearestLabel = "unlabeled";
    let nearestDistance = Number.POSITIVE_INFINITY;
    for (const stroke of strokes) {
      for (const candidate of labeled) {
        const distance = centerDistance(stroke, candidate);
        if (distance < nearestDistance) {
          nearestDistance = distance;
          nearestLabel = truncateLabel(elementLabel(candidate, boundText));
        }
      }
    }
    const near = nearestLabel === "unlabeled" ? "unlabeled" : `"${nearestLabel.replace(/"/g, "'")}"`;
    lines.push(`sketch: ${strokes.length} stroke${strokes.length === 1 ? "" : "s"} near ${near}`);
  }

  if (lines.length > SUMMARY_LINE_CAP) {
    const remaining = lines.length - SUMMARY_LINE_CAP;
    return [...lines.slice(0, SUMMARY_LINE_CAP), `…and ${remaining} more`].join("\n");
  }
  return lines.join("\n");
}
