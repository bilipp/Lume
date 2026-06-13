#if !os(tvOS)

    import SwiftUI

    /// Drag-to-reorder list of playback engines (iOS / macOS). The first engine
    /// is the primary; Lume plays each stream with it and falls back down the
    /// list whenever an engine can't start the stream. See `PlayerEnginePriority`.
    struct PlayerEnginePriorityView: View {
        /// Legacy single-engine key, kept in sync with the primary engine and used
        /// as the migration seed for the priority list.
        @AppStorage(PlayerSettings.engineKey) private var engineRaw = PlayerEngineKind.defaultValue.rawValue
        @AppStorage(PlayerSettings.enginePriorityKey) private var enginePriorityRaw = ""

        private var engines: [PlayerEngineKind] {
            PlayerEnginePriority.resolve(priorityRaw: enginePriorityRaw, legacyEngineRaw: engineRaw)
        }

        var body: some View {
            List {
                Section {
                    ForEach(engines) { kind in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(kind.displayName)
                                if kind == engines.first {
                                    Text("Primary")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.tint)
                                }
                            }
                            Text(kind.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .onMove(perform: move)
                } footer: {
                    Text("Lume plays each stream with the first engine and automatically falls back to the next if it can't be played. Drag to reorder.")
                }
            }
            .platformNavigationTitle("Player Engines")
            #if os(iOS)
                // Keep the list permanently in edit mode so the rows are always
                // draggable — no Edit button to enter reorder mode first.
                .environment(\.editMode, .constant(.active))
            #endif
        }

        private func move(from offsets: IndexSet, to destination: Int) {
            var list = engines
            list.move(fromOffsets: offsets, toOffset: destination)
            let normalized = PlayerEnginePriority.normalized(list)
            enginePriorityRaw = PlayerEnginePriority.encode(normalized)
            engineRaw = normalized.first?.rawValue ?? PlayerEngineKind.defaultValue.rawValue
        }
    }

    #Preview {
        NavigationStack {
            PlayerEnginePriorityView()
        }
    }

#endif
