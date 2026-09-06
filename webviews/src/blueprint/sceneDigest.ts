/**
 * Cheap, order-independent digest of a scene's live elements.
 *
 * Excalidraw bumps `version` on every mutation of an element, so a digest over
 * `id:version` pairs of the non-deleted elements changes exactly when the
 * visible scene changes. Selection, scroll, and zoom churn leave it untouched,
 * which is what lets the bridge tell a user edit apart from `onChange` noise.
 */
export interface DigestableElement {
  id: string;
  version?: number;
  isDeleted?: boolean;
}

export function liveElements<T extends DigestableElement>(elements: readonly T[]): T[] {
  return elements.filter((element) => !element.isDeleted);
}

export function countLiveElements(elements: readonly DigestableElement[]): number {
  return liveElements(elements).length;
}

/** FNV-1a 32-bit over the sorted `id:version` pairs, rendered as 8 hex chars. */
export function sceneDigest(elements: readonly DigestableElement[]): string {
  const pairs = liveElements(elements)
    .map((element) => `${element.id}:${element.version ?? 0}`)
    .sort();
  let hash = 0x811c9dc5;
  for (const pair of pairs) {
    for (let index = 0; index < pair.length; index += 1) {
      hash ^= pair.charCodeAt(index);
      hash = Math.imul(hash, 0x01000193) >>> 0;
    }
    hash ^= 0x1f;
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return `${pairs.length}-${hash.toString(16).padStart(8, "0")}`;
}
