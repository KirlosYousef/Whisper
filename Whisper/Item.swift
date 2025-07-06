//
//  Item.swift
//  Whisper
//
//  Created by Kirlos Yousef on 06/07/2025.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
