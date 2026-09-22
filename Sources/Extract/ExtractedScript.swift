//
//  ExtractedScript.swift
//  ragnarok-script-translator
//
//  Created by Leon Li on 2026/9/21.
//

/// All translatable scripts found in one rAthena NPC file.
struct ExtractedFile: Codable {
    /// Path relative to the swift-rathena checkout, e.g. `npc/cities/prontera.txt`.
    var file: String
    var scripts: [ExtractedScript]
}

/// One unit of text the client looks up at runtime: a page of dialog or a single menu option.
struct ExtractedScript: Codable {
    enum Kind: String, Codable {
        /// Consecutive `mes` lines shown together, joined by `\n`.
        case message
        /// One entry of a `select`, `prompt` or `menu`.
        case option
    }

    var kind: Kind
    /// Display name of the NPC the script belongs to, if known.
    var npc: String?
    /// Line in the source file where the script starts.
    var line: Int
    /// The name inside the `[...]` line a page starts with, if it has one. Translated separately so
    /// a name reads the same on every page; `{0}` stands for the player's own name.
    var speaker: String?
    /// The text as the server sends it (without the speaker line), with non-literal parts replaced
    /// by `{0}`, `{1}`, ...
    var text: String
    /// Source expressions for each placeholder, in order.
    var placeholders: [String]?
}
