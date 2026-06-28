import Foundation

/// Shared helper for the `dynamicCollection` field. Each row's child input is
/// rendered through the normal session-bound `FieldRenderer`, so it reads/writes
/// the session under a PER-ROW key. The session's `mirrorDynamicCollectionValues`
/// folds those flat per-row values back into the collection's rows array (keyed
/// by child name + `_rowId`) at validate/submit time — the same "mirror at
/// submit" pattern sysSelect uses. Both sides MUST derive the key the same way,
/// hence this single source. 1:1 with Android `engine/DynamicCollection.kt`.
enum DynamicCollectionKeys {
    /// Stable session key for a child input inside one row of a collection.
    static func childFieldID(_ collectionID: String, _ rowID: String, _ childName: String) -> String {
        "\(collectionID)::\(rowID)::\(childName)"
    }
}
