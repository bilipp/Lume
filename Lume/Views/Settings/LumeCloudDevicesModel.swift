import SwiftUI

/// Drives `LumeCloudDevicesView` and `TVLumeCloudDevicesStep`: the live
/// device list and removals.
@MainActor
@Observable
final class LumeCloudDevicesModel {
    /// Nil until the first fetch lands.
    private(set) var devices: [LumeCloudDeviceInfo]?
    private(set) var errorMessage: String?
    private(set) var isLoading = false
    /// The device whose removal is in flight.
    private(set) var removingID: UUID?
    /// The device waiting for the removal confirmation.
    var pendingRemoval: LumeCloudDeviceInfo?

    var isRemovalPresented: Bool {
        get { pendingRemoval != nil }
        set { if !newValue { pendingRemoval = nil } }
    }

    func load(using coordinator: CloudSyncCoordinator?) async {
        guard let coordinator else {
            errorMessage = LumeCloudErrorDescription.message(for: LumeCloudAccountError.unavailable)
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await coordinator.lumeCloudDevices()
            devices = fetched
            errorMessage = nil
        } catch {
            if !Task.isCancelled, !(error is CancellationError) {
                errorMessage = LumeCloudErrorDescription.message(for: error)
            }
        }
    }

    func remove(_ device: LumeCloudDeviceInfo, using coordinator: CloudSyncCoordinator?) async {
        guard !device.isCurrent, removingID == nil else { return }
        guard let coordinator else {
            errorMessage = LumeCloudErrorDescription.message(for: LumeCloudAccountError.unavailable)
            return
        }
        removingID = device.id
        errorMessage = nil
        defer { removingID = nil }
        do {
            try await coordinator.revokeLumeCloudDevice(id: device.id)
            devices?.removeAll { $0.id == device.id }
        } catch {
            errorMessage = LumeCloudErrorDescription.message(for: error)
        }
    }
}
