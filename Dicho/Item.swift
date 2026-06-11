//
//  Item.swift
//  Dicho
//
//  Created by Carlos O on 2026-06-11.
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
