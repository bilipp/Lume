//
//  Item.swift
//  Lume
//
//  Created by Philipp Bischoff on 09.04.26.
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
