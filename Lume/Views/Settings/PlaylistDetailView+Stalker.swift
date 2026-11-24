import SwiftUI

extension PlaylistDetailView {
    func startEditing() {
        editName = playlist.name
        editServerURL = playlist.serverURL
        editUsername = playlist.username
        editPassword = playlist.password
        editEPGURL = playlist.epgURL ?? ""
        editMacAddress = playlist.macAddress ?? ""
        if isStalker {
            do {
                editStalkerIdentity = try StalkerIdentityStore().load(for: playlist)
                originalStalkerIdentity = editStalkerIdentity
                identityLoaded = true
            } catch {
                editStalkerIdentity = StalkerIdentity()
                originalStalkerIdentity = StalkerIdentity()
                identityError = error.localizedDescription
                identityLoaded = false
            }
        }
        withAnimation { isEditing = true }
    }

    func saveChanges() {
        if isStalker {
            guard identityLoaded || editStalkerIdentity.isConfigured else {
                identityError = StalkerIdentityError.localIdentityRequired.localizedDescription
                return
            }
            guard StalkerMAC.isValid(editMacAddress) else {
                identityError = StalkerIdentityError.invalidProfile.localizedDescription
                return
            }
            let normalizedURL = UserEnteredURL.withDefaultScheme(editServerURL)
            let changed = normalizedURL != playlist.serverURL || editMacAddress != playlist.macAddress
                || editUsername != playlist.username || editPassword != playlist.password
                || editStalkerIdentity != originalStalkerIdentity
            if changed || playlist.stalkerIdentityRequired && playlist.stalkerIdentityReference == nil {
                showIdentityConfirmation = true
                return
            }
        }
        persistChanges()
    }

    func prepareStalkerIdentity() throws {
        // The temporary model binds the protected record to precisely the
        // reviewed account, before mutating the persisted one.
        let target = Playlist(
            name: editName, portalURL: UserEnteredURL.withDefaultScheme(editServerURL),
            macAddress: editMacAddress, username: editUsername, password: editPassword
        )
        try StalkerIdentityStore().save(editStalkerIdentity, for: target)
        playlist.stalkerIdentityReference = target.stalkerIdentityReference
        playlist.stalkerIdentityRequired = target.stalkerIdentityRequired
    }

    func finishStalkerIdentitySave(oldReference: String?, oldKey: String?) {
        guard isStalker else { return }
        if let oldReference { StalkerIdentityStore().remove(reference: oldReference) }
        if let oldKey { Task { await StalkerSessionStore.shared.clear(oldKey) } }
    }
}
