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
            let normalizedMAC = StalkerMAC.normalize(editMacAddress)
            guard StalkerMAC.isValid(normalizedMAC) else {
                identityError = StalkerIdentityError.invalidMACAddress.localizedDescription
                return
            }
            let normalizedURL = UserEnteredURL.withDefaultScheme(editServerURL)
            let changed = normalizedURL != playlist.serverURL || normalizedMAC != playlist.macAddress
                || editUsername != playlist.username || editPassword != playlist.password
                || editStalkerIdentity != originalStalkerIdentity
            if changed || playlist.stalkerIdentityRequired && playlist.stalkerIdentityReference == nil {
                showIdentityConfirmation = true
                return
            }
        }
        persistChanges()
    }

    func prepareStalkerIdentity() throws -> String? {
        let newReference = try StalkerIdentityStore().write(editStalkerIdentity, for: playlist.id)
        playlist.stalkerIdentityReference = newReference
        playlist.stalkerIdentityRequired = editStalkerIdentity.isConfigured
        return newReference
    }

    func rollbackStalkerIdentitySave(newReference: String?, oldReference: String?, oldRequired: Bool) {
        guard isStalker else { return }
        if let newReference {
            StalkerIdentityStore().remove(reference: newReference)
        }
        playlist.stalkerIdentityReference = oldReference
        playlist.stalkerIdentityRequired = oldRequired
    }

    func finishStalkerIdentitySave(oldReference: String?, oldKey: String?) {
        guard isStalker else { return }
        if let oldReference, oldReference != playlist.stalkerIdentityReference {
            StalkerIdentityStore().remove(reference: oldReference)
        }
        if let oldKey { Task { await StalkerSessionStore.shared.clear(oldKey) } }
    }
}
