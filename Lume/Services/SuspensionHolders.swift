//
//  SuspensionHolders.swift
//  Lume
//
//  A suspension any number of owners can hold at once: it stays active until
//  the last owner releases it, so one surface going away can't lift it under
//  another that still needs it.
//

nonisolated struct SuspensionHolders {
    private var owners: Set<String> = []

    var isActive: Bool {
        !owners.isEmpty
    }

    mutating func insert(_ owner: String) {
        owners.insert(owner)
    }

    mutating func remove(_ owner: String) {
        owners.remove(owner)
    }
}
