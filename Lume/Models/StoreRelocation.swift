//
//  StoreRelocation.swift
//  Lume
//
//  Moves the SwiftData stores out of the app-group container, once.
//
//  The app group (`group.com.bilipp.lume`, added for the Live Activity artwork)
//  made `ModelConfiguration.groupContainer` — `.automatic` by default — resolve
//  both stores into the shared container. iOS terminates a suspended process
//  that still holds a file lock there (RUNNINGBOARD 0xdead10cc), and a catalog
//  or guide save running as the app is backgrounded holds exactly that SQLite
//  lock. Nothing but the app process opens either store (`LumeWidgets` links no
//  SwiftData), so they belong in the app's own container, where a suspension
//  mid-write is harmless.
//

import Foundation
import OSLog

nonisolated enum StoreRelocation {
    /// Moves the store at `legacy` — plus its `-wal` / `-shm` sidecars and its
    /// `.<name>_SUPPORT` directory — to `target`, before anything opens it.
    ///
    /// A no-op when the two URLs match (no app group on this platform), when
    /// there is nothing at `legacy`, or when a store already exists at `target`.
    /// The sidecars move before the main file, so an interrupted move leaves the
    /// main file behind and the next launch finishes the job; the main file
    /// arriving at `target` is what marks the move as done.
    static func moveOutOfAppGroup(from legacy: URL, to target: URL) {
        let legacy = legacy.standardizedFileURL
        let target = target.standardizedFileURL
        guard legacy != target else { return }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: legacy.path) else { return }
        guard !fileManager.fileExists(atPath: target.path) else {
            // A store is already in place. Leave the stray copy alone rather than
            // guess which one holds the user's data.
            Logger.database.error("Store relocation skipped: \(target.lastPathComponent, privacy: .public) exists in both containers")
            return
        }

        let sourceDirectory = legacy.deletingLastPathComponent()
        let targetDirectory = target.deletingLastPathComponent()
        let storeName = legacy.lastPathComponent
        let supportName = ".\(legacy.deletingPathExtension().lastPathComponent)_SUPPORT"

        do {
            try fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
            let siblings = try fileManager.contentsOfDirectory(atPath: sourceDirectory.path)
            let sidecars = siblings.filter { name in
                name == supportName || (name.hasPrefix(storeName) && name != storeName)
            }
            for name in sidecars {
                let destination = targetDirectory.appending(path: name)
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: sourceDirectory.appending(path: name), to: destination)
            }
            try fileManager.moveItem(at: legacy, to: target)
            Logger.database.info("Moved \(storeName, privacy: .public) out of the app-group container")
        } catch {
            // Opening the store in place is still correct, just exposed to the
            // suspension kill; try again next launch.
            Logger.database.error("Store relocation failed for \(storeName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
