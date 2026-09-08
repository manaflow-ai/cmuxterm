import { describe, expect, test } from "bun:test";
import enMessages from "../messages/en.json";
import {
  pruneClientMessages,
  sharedClientMessages,
} from "../i18n/client-messages";

describe("client message catalogs", () => {
  test("the shared catalog drops subtree-only namespaces and keeps the dashboard", () => {
    const shared = sharedClientMessages(enMessages);

    expect(shared.docs).toBeUndefined();
    expect(shared.community).toBeUndefined();
    expect(shared.dashboard).toBeDefined();
    expect(shared.common).toBeDefined();
    expect(shared.landing).toBeDefined();
    // The dropped namespaces are the bulk of the catalog.
    const before = JSON.stringify(pruneClientMessages(enMessages)).length;
    const after = JSON.stringify(shared).length;
    expect(after).toBeLessThan(before * 0.5);
  });

  test("the subtree catalog keeps docs and community for their nested providers", () => {
    const pruned = pruneClientMessages(enMessages);

    expect(pruned.docs).toBeDefined();
    expect(pruned.community).toBeDefined();
    expect(enMessages.docs).toBeDefined();
  });
});
