import {
  type BlueprintElement,
  boundTextByContainer,
  CONNECTOR_TYPES,
  elementLabel,
  SHAPE_TYPES,
  sortByPosition,
  truncateLabel,
} from "./elementModel";

function mermaidNodeId(id: string, taken: Set<string>): string {
  let base = id.replace(/[^A-Za-z0-9_]/g, "_");
  if (!/^[A-Za-z_]/.test(base)) {
    base = `n_${base}`;
  }
  let candidate = base;
  let suffix = 2;
  while (taken.has(candidate)) {
    candidate = `${base}_${suffix}`;
    suffix += 1;
  }
  taken.add(candidate);
  return candidate;
}

function mermaidLabel(text: string): string {
  return truncateLabel(text, 120).replace(/"/g, "#quot;");
}

function nodeDeclaration(type: string, id: string, label: string): string {
  const quotedLabel = `"${mermaidLabel(label)}"`;
  switch (type) {
    case "diamond":
      return `${id}{${quotedLabel}}`;
    case "ellipse":
      return `${id}((${quotedLabel}))`;
    default:
      return `${id}[${quotedLabel}]`;
  }
}

/**
 * Best-effort projection of a scene onto a Mermaid `flowchart LR`.
 *
 * Every shape becomes a node (labeled by its bound text, or by its type when
 * unlabeled), every bound arrow or line an edge. Free text and freehand
 * strokes are omitted: Mermaid has no counterpart for them.
 */
export function elementsToMermaid(elements: readonly BlueprintElement[]): string {
  const live = elements.filter((element) => !element.isDeleted);
  const boundText = boundTextByContainer(live);
  const shapes = sortByPosition(live.filter((element) => SHAPE_TYPES.has(element.type)));
  const connectors = sortByPosition(live.filter((element) => CONNECTOR_TYPES.has(element.type)));

  const taken = new Set<string>();
  const nodeIds = new Map<string, string>();
  const lines = ["flowchart LR"];
  for (const shape of shapes) {
    const nodeId = mermaidNodeId(shape.id, taken);
    nodeIds.set(shape.id, nodeId);
    const label = elementLabel(shape, boundText) || shape.type;
    lines.push(`  ${nodeDeclaration(shape.type, nodeId, label)}`);
  }

  for (const connector of connectors) {
    const from = connector.startBinding?.elementId;
    const to = connector.endBinding?.elementId;
    if (!from || !to) {
      continue;
    }
    const fromId = nodeIds.get(from);
    const toId = nodeIds.get(to);
    if (!fromId || !toId) {
      continue;
    }
    const label = elementLabel(connector, boundText);
    const edge = connector.type === "arrow" ? "-->" : "---";
    if (label) {
      lines.push(`  ${fromId} ${edge}|"${mermaidLabel(label)}"| ${toId}`);
    } else {
      lines.push(`  ${fromId} ${edge} ${toId}`);
    }
  }

  return lines.join("\n");
}
