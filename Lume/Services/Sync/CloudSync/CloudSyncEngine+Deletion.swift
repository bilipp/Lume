//
//  CloudSyncEngine+Deletion.swift
//  Lume
//
//  User-initiated playlist deletion, run on the engine actor.
//
//  Deleting the *last* playlist empties the catalog store — exactly the
//  signature `localCatalogReadiness()` treats as a lost `default.store`. A
//  deletion left for the reconciler to *infer* (local absent vs. surviving
//  mirror) therefore never propagates: the integrity gate fires first, drops
//  the shadow, and the recovery pull resurrects the playlist and re-triggers a
//  full catalog sync (#136). Propagating the deletion here, as one explicit
//  operation, removes anything to resurrect — and because it runs on the same
//  actor as `reconcile()`, no pass can interleave and misread the half-applied
//  state.
//

import Foundation
import SwiftData

extension CloudSyncEngine {
    /// Delete `id`'s playlist everywhere this device controls: the CloudKit
    /// mirror (CloudKit then exports a genuine deletion to sibling devices),
    /// the shadow baselines, and the local catalog.
    ///
    /// Ordered cloud-first so a crash mid-way fails safe: the local playlist
    /// survives with no mirror or shadow, and the next reconcile pushes it back
    /// to the cloud — a delete that "didn't take", never a resurrection loop
    /// and never an unintended cloud wipe.
    func deletePlaylist(id: UUID) throws {
        let key = id.uuidString

        let mirrors = try cloudContext.fetch(
            FetchDescriptor<SyncedPlaylist>(predicate: #Predicate { $0.id == id })
        )
        for mirror in mirrors {
            cloudContext.delete(mirror)
        }
        // Content-state mirrors are deleted across *all* profiles — the
        // reconcile pass's garbage collection only sees the active profile's
        // mirrors, and the playlist is gone for every profile.
        let states = try cloudContext.fetch(
            FetchDescriptor<UserContentState>(predicate: #Predicate { $0.contentId.starts(with: key) })
        )
        for state in states {
            cloudContext.delete(state)
        }

        shadow.setPlaylistShadow(key, nil)
        for contentID in shadow.contentShadowIDs() where contentID.hasPrefix(key) {
            shadow.setContentShadow(contentID, nil)
        }

        if cloudContext.hasChanges { try cloudContext.save() }
        shadow.persist()

        // The `Playlist` row gets its own save so the UI's `@Query`s drop it
        // promptly; the orphaned-content sweep below can take minutes on a
        // large catalog. No suspension points separate the two saves, so a
        // reconcile still can't observe the row-less intermediate state.
        let locals = try catalogContext.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == id })
        )
        if !locals.isEmpty {
            EPGSourceReconciler.remove(playlistID: id, in: catalogContext)
            for local in locals {
                catalogContext.delete(local)
            }
            try catalogContext.save()
        }

        PlaylistDeletion.removeOrphanedContent(playlistID: id, in: catalogContext)
        if catalogContext.hasChanges { try catalogContext.save() }
    }
}
