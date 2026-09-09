/// One path/provenance/sequence entry in the artifact recency heap.
struct ChatArtifactRecencyHeapEntry {
    let path: String
    /// Lower values are weaker capture provenance and are evicted first.
    let evictionPriority: Int
    let seq: Int
}
