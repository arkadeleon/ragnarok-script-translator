//
//  TranslationRequest.swift
//  ragnarok-script-translator
//
//  Created by Leon Li on 2026/9/23.
//

import Foundation

/// What the model is sent: the texts to translate, after the lines that precede them in the script.
struct TranslationRequest: Encodable {
    var context: [TranslationContext]
    var items: [TranslationItem]
}

/// One text to translate, with who says it and whether it is dialogue or a menu option.
struct TranslationItem: Encodable {
    var id: Int
    var npc: String?
    var kind: ExtractedScript.Kind
    var text: String
}

/// A line shown before the items for continuity, with its translation when there is one already.
struct TranslationContext: Encodable {
    var npc: String?
    var kind: ExtractedScript.Kind
    var text: String
    var translation: String?
}
