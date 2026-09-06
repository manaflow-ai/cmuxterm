import { describe, expect, test } from "bun:test";
import type { BlueprintElement } from "../src/blueprint/elementModel";
import { elementsToMermaid } from "../src/blueprint/mermaidExport";

function shape(id: string, type: string, x: number, y: number): BlueprintElement {
  return { id, type, x, y, width: 100, height: 50 };
}

function label(id: string, containerId: string, text: string): BlueprintElement {
  return { id, type: "text", x: 0, y: 0, width: 1, height: 1, text, containerId };
}

function arrow(id: string, from: string, to: string, y = 0): BlueprintElement {
  return {
    id,
    type: "arrow",
    x: 0,
    y,
    width: 10,
    height: 0,
    startBinding: { elementId: from },
    endBinding: { elementId: to },
  };
}

describe("elementsToMermaid", () => {
  test("emits nodes by shape kind and edges for bound arrows", () => {
    const mermaid = elementsToMermaid([
      shape("web", "rectangle", 0, 0),
      label("l1", "web", "Web"),
      shape("decide", "diamond", 200, 0),
      label("l2", "decide", "Cached?"),
      shape("db", "ellipse", 400, 0),
      label("l3", "db", "DB"),
      arrow("e1", "web", "decide"),
      label("l4", "e1", "request"),
      arrow("e2", "decide", "db", 10),
    ]);
    expect(mermaid).toBe(
      [
        "flowchart LR",
        '  web["Web"]',
        '  decide{"Cached?"}',
        '  db(("DB"))',
        '  web -->|"request"| decide',
        "  decide --> db",
      ].join("\n"),
    );
  });

  test("labels unlabeled shapes by type, sanitizes quotes, and skips unbound arrows", () => {
    const mermaid = elementsToMermaid([
      shape("1-box", "rectangle", 0, 0),
      shape("quote", "rectangle", 0, 100),
      label("lq", "quote", 'Say "hi"'),
      { id: "loose", type: "arrow", x: 0, y: 0, width: 5, height: 5, startBinding: { elementId: "quote" }, endBinding: null },
      { id: "line1", type: "line", x: 0, y: 0, width: 5, height: 5, startBinding: { elementId: "1-box" }, endBinding: { elementId: "quote" } },
    ]);
    expect(mermaid).toBe(
      ["flowchart LR", '  n_1_box["rectangle"]', '  quote["Say #quot;hi#quot;"]', "  n_1_box --- quote"].join("\n"),
    );
  });

  test("orders nodes top to bottom then left to right and ignores deleted elements", () => {
    const mermaid = elementsToMermaid([
      shape("c", "rectangle", 0, 100),
      shape("b", "rectangle", 200, 0),
      shape("a", "rectangle", 0, 0),
      { ...shape("gone", "rectangle", 0, 0), isDeleted: true },
    ]);
    expect(mermaid.split("\n").slice(1)).toEqual(['  a["rectangle"]', '  b["rectangle"]', '  c["rectangle"]']);
  });
});
