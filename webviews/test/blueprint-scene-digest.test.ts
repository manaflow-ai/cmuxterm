import { describe, expect, test } from "bun:test";
import { countLiveElements, sceneDigest } from "../src/blueprint/sceneDigest";

describe("sceneDigest", () => {
  test("is stable across element order", () => {
    const a = [
      { id: "one", version: 3 },
      { id: "two", version: 1 },
    ];
    const b = [...a].reverse();
    expect(sceneDigest(a)).toBe(sceneDigest(b));
  });

  test("changes when an element's version changes", () => {
    const before = sceneDigest([{ id: "one", version: 3 }]);
    const after = sceneDigest([{ id: "one", version: 4 }]);
    expect(before).not.toBe(after);
  });

  test("ignores deleted elements and reports the live count", () => {
    const elements = [
      { id: "one", version: 3 },
      { id: "gone", version: 9, isDeleted: true },
    ];
    expect(sceneDigest(elements)).toBe(sceneDigest([{ id: "one", version: 3 }]));
    expect(countLiveElements(elements)).toBe(1);
    expect(sceneDigest(elements).startsWith("1-")).toBe(true);
  });

  test("distinguishes an empty scene from a scene with elements", () => {
    expect(sceneDigest([])).not.toBe(sceneDigest([{ id: "one", version: 0 }]));
  });
});
