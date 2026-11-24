import SwiftUI

struct StalkerIdentitySection: View {
    @Binding var identity: StalkerIdentity

    var body: some View {
        Section {
            optionalField("Existing protocol serial number", value: $identity.serialNumber)
            optionalField("Existing device ID 1", value: $identity.deviceId1)
            optionalField("Existing device ID 2", value: $identity.deviceId2)
            optionalField("Existing signature 1", value: $identity.signature1)
            optionalField("Existing signature 2", value: $identity.signature2)
        } header: {
            Text("Advanced Stalker identity")
        } footer: {
            Text("Use only your existing registered values. Off omits a field; on with no text sends an explicitly empty value. Advanced values stay on this device and are not synced or exported.")
        }
    }

    private func optionalField(_ title: LocalizedStringKey, value: Binding<String?>) -> some View {
        VStack(alignment: .leading) {
            Toggle(title, isOn: Binding(
                get: { value.wrappedValue != nil },
                set: { value.wrappedValue = $0 ? (value.wrappedValue ?? "") : nil }
            ))
            if value.wrappedValue != nil {
                SecureField(title, text: Binding(
                    get: { value.wrappedValue ?? "" },
                    set: { value.wrappedValue = $0 }
                ))
                #if os(iOS) || os(tvOS) || os(visionOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
            }
        }
        .privacySensitive()
    }
}
