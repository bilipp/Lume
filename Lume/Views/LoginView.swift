import SwiftUI
import SwiftData

struct LoginView: View {
    @Environment(\.modelContext) private var modelContext
    
    @State private var name = ""
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Playlist Details")) {
                    TextField("Name (e.g. My IPTV)", text: $name)
                    TextField("Server URL (http://...)", text: $serverURL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    SecureField("Password", text: $password)
                }
                
                if let errorMessage = errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(.red)
                    }
                }
                
                Button(action: login) {
                    if isLoading {
                        ProgressView()
                    } else {
                        Text("Add Playlist")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .disabled(isLoading || serverURL.isEmpty || username.isEmpty || password.isEmpty)
            }
            .navigationTitle("Add Playlist")
        }
    }
    
    private func login() {
        isLoading = true
        errorMessage = nil
        
        Task {
            let playlist = Playlist(
                name: name.isEmpty ? "My Playlist" : name,
                serverURL: serverURL,
                username: username,
                password: password
            )
            
            let client = XtreamClient()
            do {
                let info = try await client.getInfo(playlist: playlist)
                print("Server info fetched successfully: \(info)")
                
                await MainActor.run {
                    playlist.serverTimezone = info.serverInfo.timezone
                    // Map other fields if needed from info.userInfo
                    playlist.userStatus = info.userInfo.status
                    playlist.maxConnections = String(info.userInfo.maxConnections ?? "0")
                    playlist.activeConnections = String(info.userInfo.activeCons ?? "0")
                    playlist.expDate = info.userInfo.expDate
                    
                    modelContext.insert(playlist)
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Failed to connect: \(error.localizedDescription)"
                    isLoading = false
                }
            }
        }
    }
}

#Preview {
    LoginView()
}
