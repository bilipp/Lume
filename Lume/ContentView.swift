import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var playlists: [Playlist]

    var body: some View {
        if playlists.isEmpty {
            LoginView()
        } else {
            NavigationViewWrapper {
                List {
                    ForEach(playlists) { playlist in
                        NavigationLink {
                            Text("Playlist: \(playlist.name)")
                        } label: {
                            Text(playlist.name)
                        }
                    }
                    .onDelete(perform: deletePlaylists)
                }
#if os(macOS)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200)
#endif
                .toolbar {
#if os(iOS)
                    ToolbarItem(placement: .navigationBarTrailing) {
                        EditButton()
                    }
#endif
                    ToolbarItem {
                        Button(action: {
                            // TODO: Show LoginView modally
                        }) {
                            Label("Add Playlist", systemImage: "plus")
                        }
                    }
                }
            }
        }
    }

    private func deletePlaylists(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                modelContext.delete(playlists[index])
            }
        }
    }
}

fileprivate struct NavigationViewWrapper<Content: View>: View {
    let content: () -> Content

    var body: some View {
#if os(macOS)
        NavigationSplitView {
            content()
        } detail: {
            Text("Select a playlist")
        }
#else
        content()
#endif
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Playlist.self, inMemory: true)
}
