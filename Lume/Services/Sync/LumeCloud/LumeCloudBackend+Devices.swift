import Foundation
import LumeCloudKit

/// The account's device list, this device's name in it, and removing other
/// devices from it.
extension LumeCloudBackend {
    /// The account's devices that still sync: this device first, then the most
    /// recently seen. Revoked devices are left out.
    func devices() async throws -> [LumeCloudDeviceInfo] {
        let currentID = settings.deviceID
        let devices = try await authenticated { client in try await client.devices() }
        return devices
            .filter { !$0.revoked }
            .map { device in
                LumeCloudDeviceInfo(
                    id: device.id,
                    name: device.name,
                    platform: device.platform.rawValue,
                    createdAt: Date(lumeCloudMilliseconds: Double(device.createdAt)),
                    lastSeen: Date(lumeCloudMilliseconds: Double(device.lastSeen)),
                    isCurrent: device.id == currentID
                )
            }
            .sorted { lhs, rhs in
                if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
                return lhs.lastSeen > rhs.lastSeen
            }
    }

    /// Removes another device from the account; it stops syncing on its next
    /// request. This device leaves through `leave()` instead.
    func revokeDevice(id: UUID) async throws {
        guard id != settings.deviceID else { throw LumeCloudAccountError.cannotRevokeCurrentDevice }
        try await authenticated { client in try await client.revokeDevice(id: id) }
    }

    /// Renames this device. Joined, the server's device list follows
    /// (`POST /v1/devices` updates a registered device); a blank name restores
    /// the generic model name.
    func renameDevice(to name: String) async throws {
        settings.deviceName = name
        guard isJoined else { return }
        let deviceID = settings.deviceID
        let deviceName = settings.deviceName
        _ = try await authenticated { client in
            try await client.registerDevice(id: deviceID, name: deviceName, platform: .current)
        }
    }
}
