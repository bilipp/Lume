import Foundation
@testable import Lume
import Testing

@MainActor
struct PlayerVolumeStoreTests {
    private func storedLevel(_ defaults: UserDefaults) -> Float? {
        defaults.object(forKey: PlayerSettings.volumeKey) == nil
            ? nil : defaults.float(forKey: PlayerSettings.volumeKey)
    }

    @Test func `defaults to full volume, unmuted`() {
        withIsolatedDefaults { defaults in
            let store = PlayerVolumeStore(defaults: defaults)
            #expect(store.level == 1.0)
            #expect(store.isMuted == false)
            #expect(store.effective == 1.0)
        }
    }

    @Test func `loads the stored level`() {
        withIsolatedDefaults { defaults in
            defaults.set(Float(0.3), forKey: PlayerSettings.volumeKey)
            #expect(PlayerVolumeStore(defaults: defaults).level == 0.3)
        }
    }

    @Test func `setLevel does not persist until commit`() {
        withIsolatedDefaults { defaults in
            let store = PlayerVolumeStore(defaults: defaults)
            store.setLevel(0.4)
            #expect(store.level == 0.4)
            #expect(storedLevel(defaults) == nil)
            store.commit()
            #expect(storedLevel(defaults) == 0.4)
        }
    }

    @Test func `setLevel clamps`() {
        withIsolatedDefaults { defaults in
            let store = PlayerVolumeStore(defaults: defaults)
            store.setLevel(1.7)
            #expect(store.level == 1)
            store.setLevel(-0.2)
            #expect(store.level == 0)
        }
    }

    @Test func `mute is never written to defaults`() {
        withIsolatedDefaults { defaults in
            let store = PlayerVolumeStore(defaults: defaults)
            store.toggleMute()
            #expect(store.isMuted)
            #expect(store.effective == 0)
            store.commit()
            #expect(storedLevel(defaults) == 1.0)
            #expect(PlayerVolumeStore(defaults: defaults).isMuted == false)
        }
    }

    @Test func `toggleMute restores the prior level`() {
        withIsolatedDefaults { defaults in
            let store = PlayerVolumeStore(defaults: defaults)
            store.setLevel(0.6)
            store.toggleMute()
            #expect(store.isMuted)
            #expect(store.level == 0.6)
            store.toggleMute()
            #expect(store.isMuted == false)
            #expect(store.effective == 0.6)
        }
    }

    @Test func `toggleMute from zero restores the last audible level`() {
        withIsolatedDefaults { defaults in
            let store = PlayerVolumeStore(defaults: defaults)
            store.setLevel(0.7)
            store.setLevel(0)
            store.toggleMute()
            #expect(store.isMuted == false)
            #expect(store.level == 0.7)
        }
    }

    @Test func `toggleMute from a stored zero restores half volume`() {
        withIsolatedDefaults { defaults in
            defaults.set(Float(0), forKey: PlayerSettings.volumeKey)
            let store = PlayerVolumeStore(defaults: defaults)
            store.toggleMute()
            #expect(store.isMuted == false)
            #expect(store.level == 0.5)
            #expect(PlayerSettings.volume(in: defaults) == 0.5)
        }
    }

    @Test func `dragging while muted unmutes`() {
        withIsolatedDefaults { defaults in
            let store = PlayerVolumeStore(defaults: defaults)
            store.toggleMute()
            store.setLevel(0.3)
            #expect(store.isMuted == false)
            #expect(store.effective == 0.3)
        }
    }

    @Test func `step clamps at both ends`() {
        withIsolatedDefaults { defaults in
            let store = PlayerVolumeStore(defaults: defaults)
            store.step(up: true)
            #expect(store.level == 1)
            store.setLevel(0.05)
            store.step(up: false)
            #expect(store.level == 0)
            store.step(up: false)
            #expect(store.level == 0)
        }
    }

    @Test func `step persists the new level`() {
        withIsolatedDefaults { defaults in
            let store = PlayerVolumeStore(defaults: defaults)
            store.step(up: false)
            #expect(store.level == 0.9)
            #expect(storedLevel(defaults) == 0.9)
            #expect(PlayerVolumeStore(defaults: defaults).level == 0.9)
        }
    }
}
