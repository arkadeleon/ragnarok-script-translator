//
//  Segment.swift
//  ragnarok-script-translator
//
//  Created by Leon Li on 2026/9/21.
//

/// A string expression split into literal text and the expressions concatenated into it.
enum Segment: Equatable {
    case literal(String)
    case placeholder(String)
}

/// One `mes` argument: a single line of dialog.
struct DialogLine {
    var segments: [Segment]
    var line: Int
}
