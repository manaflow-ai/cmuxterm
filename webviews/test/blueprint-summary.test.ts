import { describe, expect, test } from "bun:test";
import type { BlueprintElement } from "../src/blueprint/elementModel";
import { SUMMARY_LINE_CAP, summarizeElements } from "../src/blueprint/summary";

function box(id: string, x: number, y: number, extra: Partial<BlueprintElement> = {}): BlueprintElement {
  return { id, type: "rectangle", x, y, width: 120, height: 60, ...extra };
}

function boundText(id: string, containerId: string, text: string): BlueprintElement {
  return { id, type: "text", x: 0, y: 0, width: 10, height: 10, text, containerId };
}

describe("summarizeElements", () => {
  test("renders shapes with their bound labels and geometry", () => {
    const summary = summarizeElements([
      box("api-gateway-1", 10.4, 20.6),
      boundText("t1", "api-gateway-1", "API Gateway"),
    ]);
    expect(summary).toBe('#api-gate rectangle "API Gateway" (10,21 120x60)');
  });

  test("renders arrows as edges between shape ids", () => {
    const summary = summarizeElements([
      box("a", 0, 0),
      boundText("ta", "a", "Client"),
      box("b", 300, 0),
      boundText("tb", "b", "Server"),
      {
        id: "arrow1",
        type: "arrow",
        x: 120,
        y: 30,
        width: 180,
        height: 0,
        startBinding: { elementId: "a" },
        endBinding: { elementId: "b" },
      },
      boundText("tarrow", "arrow1", "HTTP"),
    ]);
    // Reading order is top to bottom, then left to right: both boxes sit at y=0.
    expect(summary.split("\n")).toEqual([
      '#a rectangle "Client" (0,0 120x60)',
      '#b rectangle "Server" (300,0 120x60)',
      '#arrow1 arrow #a -> #b "HTTP"',
    ]);
  });

  test("collapses freehand strokes into one line near the closest label", () => {
    const summary = summarizeElements([
      box("far", 1000, 1000),
      boundText("tfar", "far", "Far away"),
      box("near", 0, 0),
      boundText("tnear", "near", "Cache"),
      { id: "s1", type: "freedraw", x: 10, y: 70, width: 30, height: 30 },
      { id: "s2", type: "freedraw", x: 20, y: 80, width: 30, height: 30 },
    ]);
    expect(summary.split("\n").at(-1)).toBe('sketch: 2 strokes near "Cache"');
  });

  test("skips deleted elements and reports empty scenes", () => {
    expect(summarizeElements([])).toBe("(empty blueprint)");
    expect(summarizeElements([box("x", 0, 0, { isDeleted: true })])).toBe("(empty blueprint)");
  });

  test("truncates long labels and caps the line count", () => {
    const elements: BlueprintElement[] = [];
    for (let index = 0; index < SUMMARY_LINE_CAP + 5; index += 1) {
      elements.push(box(`b${index}`, 0, index * 100));
    }
    elements.push(boundText("long", "b0", "x".repeat(200)));
    const lines = summarizeElements(elements).split("\n");
    expect(lines).toHaveLength(SUMMARY_LINE_CAP + 1);
    expect(lines.at(-1)).toBe("…and 5 more");
    expect(lines[0]).toBe(`#b0 rectangle "${"x".repeat(59)}…" (0,0 120x60)`);
  });
});
