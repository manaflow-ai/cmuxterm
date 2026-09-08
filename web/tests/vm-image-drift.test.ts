import { describe, expect, test } from "bun:test";
import { devboxImageInputPaths, driftedInputs } from "../scripts/check-devbox-image-drift";

describe("devbox image drift", () => {
  test("every file the image is built from is an input", () => {
    const paths = devboxImageInputPaths();
    // The shell config is the case that motivated the check: it merged to main
    // and reached no machine, because nothing rebaked the snapshot.
    expect(paths).toContain("web/services/vms/images/devbox/cmux-bashrc");
    expect(paths).toContain("web/services/vms/images/devbox/Dockerfile");
    expect(paths).toContain("web/scripts/build-devbox-freestyle.ts");
    expect(paths).toContain("web/services/vms/images/devbox/desktop/cmux-desktop-boot");
    expect(new Set(paths).size).toBe(paths.length);
  });

  test("an input that changed since the bake is drift", () => {
    const baked = new Map([["a", "one"], ["b", "two"]]);
    const tree = new Map([["a", "one"], ["b", "two-changed"]]);
    expect(driftedInputs(baked, tree)).toEqual(["b"]);
  });

  test("an input added or deleted since the bake is drift", () => {
    expect(driftedInputs(new Map([["a", null]]), new Map([["a", "new file"]]))).toEqual(["a"]);
    expect(driftedInputs(new Map([["a", "was there"]]), new Map([["a", null]]))).toEqual(["a"]);
  });

  test("an unchanged tree is not drift", () => {
    const inputs = new Map([["a", "one"], ["b", "two"]]);
    expect(driftedInputs(inputs, new Map(inputs))).toEqual([]);
  });
});
