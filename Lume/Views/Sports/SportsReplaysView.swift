//
//  SportsReplaysView.swift
//  Lume
//
//  Replay browsing uses the existing fixture cards and recording playback. Date,
//  team and competition filters are shared by all platforms; no second recorder.
//

import SwiftUI

struct SportsReplaysView: View {
    let games: [SportsReplayGame]
    /// Library files no fixture could be matched to.
    var others: [SportsLibraryReplay] = []
    /// Called as a replay's player or game sheet closes, so the caller can
    /// re-read the progress it left.
    var onPlaybackEnd: () -> Void = {}
    @Environment(\.modelContext) private var context
    @State private var player = RecordingsLibraryModel()
    @State private var follows = SportsFollowService.shared
    @State private var filter = SportsReplayFilter()
    @State private var browse = false
    @State private var showingFilters = false
    @State private var customStart = Date().addingTimeInterval(-7 * 86400)
    @State private var customEnd = Date()
    @State private var selected: SportsReplayGame?
    @State private var progressRevision = 0
    #if os(tvOS)
        @FocusState private var focusedRange: SportsReplayRange?
    #endif

    private var customDates: ClosedRange<Date> {
        min(customStart, customEnd) ... max(customStart, customEnd)
    }

    /// The filter as chosen, with the dates and follows it cannot hold itself.
    private var activeFilter: SportsReplayFilter {
        var filter = filter
        filter.custom = customDates
        filter.followedTeamIDs = Set(follows.followedTeamIds)
        return filter
    }

    private var filtered: [SportsReplayGame] {
        activeFilter.apply(games)
    }

    var body: some View {
        #if os(tvOS)
            NavigationStack { content }
        #else
            content
        #endif
    }

    private var content: some View {
        VStack(spacing: 12) {
            controls
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let interval = filter.range.interval(now: Date(), days: filter.recentDays, custom: customDates) {
                        Text(interval.start.formatted(date: .abbreviated, time: .omitted) + " – " + interval.end.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if filtered.isEmpty, others.isEmpty {
                        ContentUnavailableView {
                            Label("No replays", systemImage: "play.rectangle")
                        } actions: {
                            Button("Clear dates") { filter.range = .season }
                            Button("Browse season") { filter.range = .season; browse = true }
                        }
                    } else {
                        continueWatching.id(progressRevision)
                        replayGroups
                    }
                    moreReplays
                    if filter.range == .recent {
                        Button("Load older") { filter.recentDays += 14 }
                            .frame(minHeight: 44)
                    }
                }
                .padding()
            }
        }
        .sheet(isPresented: $showingFilters) { filters }
        .replayPlayer(player)
        .sheet(item: $selected, onDismiss: { progressRevision += 1; onPlaybackEnd() }, content: { SportsReplayDetail(game: $0) })
        .onChange(of: player.playingMedia == nil) { _, closed in if closed { onPlaybackEnd() } }
        .onChange(of: filter.range) { _, value in if value == .custom { showingFilters = true } }
    }

    /// Files ESPN has no fixture for, under the same filter as the games.
    /// Those whose source named the exact event share one card per event,
    /// built from that source's own title and date, with each file a version;
    /// nothing about teams or a score is inferred. Those known only by their
    /// league are listed as unmatched.
    @ViewBuilder
    private var moreReplays: some View {
        let files = activeFilter.apply(others)
        let events = Dictionary(grouping: files.filter { $0.event != nil }, by: { $0.event ?? "" })
            .values.sorted { ($0[0].day ?? .distantPast) > ($1[0].day ?? .distantPast) }
        let unmatched = files.filter { $0.event == nil }
        if !events.isEmpty {
            Text("More Replays").font(.headline)
            ForEach(events, id: \.[0].id) { versions in
                fileRow(versions)
                    .padding()
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        if !unmatched.isEmpty {
            Text("Unmatched").font(.headline)
            ForEach(unmatched) { fileRow([$0]) }
        }
    }

    /// One file plays from its row; several are offered as versions first.
    @ViewBuilder
    private func fileRow(_ versions: [SportsLibraryReplay]) -> some View {
        let file = versions[0]
        let label = HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: file.title)
                let details = [file.league, file.dayLabel ?? ""].filter { !$0.isEmpty }
                if !details.isEmpty {
                    Text(verbatim: details.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: versions.contains { $0.progress > 0 } ? "play.circle" : "play.fill")
        }
        .frame(minHeight: 44)
        if versions.count == 1 {
            Button { player.playingMedia = file.media(in: context) } label: { label }
                .buttonStyle(.plain)
        } else {
            Menu {
                ForEach(versions) { version in
                    Button(version.source.isEmpty ? version.title : version.source) {
                        player.playingMedia = version.media(in: context)
                    }
                }
            } label: { label }
                .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var continueWatching: some View {
        let namespace = RecordingServerConfigService.shared.activeServer?.progressNamespace
        let continuing = filtered.filter { game in
            game.recordings.contains { RecordingProgressStore.resumePosition(for: $0, namespace: namespace) > 0 }
                || game.library.contains { $0.progress > 0 }
        }
        if !continuing.isEmpty {
            Text("Continue Watching").font(.headline)
            ScrollView(.horizontal) {
                HStack(spacing: 16) {
                    ForEach(continuing) { game in card(game).frame(width: 320) }
                }
            }
        }
    }

    private var controls: some View {
        VStack {
            TextField("Search replays", text: $filter.query)
            #if !os(tvOS)
                .textFieldStyle(.roundedBorder)
            #endif
            HStack {
                #if os(tvOS)
                    ForEach(SportsReplayRange.allCases, content: rangePill)
                    Spacer()
                    Menu { scopePicker } label: { Label(filter.myTeams ? "My Teams" : "All", systemImage: "star") }
                        .buttonStyle(TVCardButtonStyle(focusScale: 1.02))
                #else
                    Picker("Dates", selection: $filter.range) {
                        ForEach(SportsReplayRange.allCases) { Text($0.title).tag($0) }
                    }
                    scopePicker
                #endif
                Button { showingFilters = true } label: { Label("Filters", systemImage: "line.3.horizontal.decrease") }
            }
        }.padding(.horizontal)
    }

    private var scopePicker: some View {
        Picker("Scope", selection: $filter.myTeams) {
            Text("All").tag(false)
            Text("My Teams").tag(true)
        }
    }

    #if os(tvOS)
        /// The date ranges as the hub's own segment pills, so the remote moves
        /// across them the way it does across Yesterday / Today / Upcoming.
        private func rangePill(_ value: SportsReplayRange) -> some View {
            Button {
                filter.range = value
            } label: {
                TVSportsPillLabel(
                    title: value.title,
                    font: .callout.weight(.semibold),
                    isFocused: focusedRange == value,
                    isActive: filter.range == value,
                    horizontalPadding: 22,
                    verticalPadding: 12,
                    cornerRadius: 12
                )
            }
            .buttonStyle(TVCardButtonStyle(focusScale: 1.03))
            .focused($focusedRange, equals: value)
            .animation(.easeOut(duration: 0.18), value: focusedRange == value)
        }
    #endif

    @ViewBuilder
    private var replayGroups: some View {
        if browse {
            SportsReplayBrowser(games: filtered, card: card)
        } else if filter.recentlyAdded {
            // In the order they were added; day headings would regroup them by kickoff.
            ForEach(filtered) { card($0) }
        } else {
            let groups = Dictionary(grouping: filtered) { Calendar.current.startOfDay(for: $0.fixture.startDate) }
            ForEach(groups.keys.sorted(by: >), id: \.self) { day in
                Text(verbatim: SportsFixtureGroup.dayLabel(day, calendar: .current)).font(.headline)
                ForEach(groups[day] ?? []) { card($0) }
            }
        }
    }

    @ViewBuilder
    private func card(_ game: SportsReplayGame) -> some View {
        #if os(tvOS)
            TVFixtureLogoCard(fixture: game.fixture, hidesResults: SportsSyncService.hidesReplayScores) { selected = game }
        #else
            FixtureCard(
                fixture: game.fixture, resolved: [], isFollowed: { follows.isFollowing($0.id) }, hidesResults: SportsSyncService.hidesReplayScores,
                onOpenDetail: { selected = game }, onWatch: { _ in }, onFollowToggle: { follows.toggle($0.id, kind: .team) }, onPickChannel: {}
            )
        #endif
    }

    private var filters: some View {
        NavigationStack {
            Form {
                Toggle("Browse season", isOn: $browse)
                Toggle("Recently Added", isOn: $filter.recentlyAdded)
                Picker("League", selection: $filter.leagueID) {
                    Text("All").tag("")
                    ForEach(Array(Set(games.map(\.fixture.leagueId))).sorted(), id: \.self) { id in
                        Text(verbatim: games.first { $0.fixture.leagueId == id }?.fixture.leagueName ?? id).tag(id)
                    }
                }
                Picker("Season", selection: $filter.season) {
                    Text("All").tag(Int?.none)
                    ForEach(Array(Set(games.compactMap(\.fixture.seasonYear))).sorted().reversed(), id: \.self) { Text(verbatim: String($0)).tag(Optional($0)) }
                }
                Picker("Phase", selection: $filter.phase) {
                    Text("All").tag("")
                    ForEach(Array(Set(games.compactMap(\.fixture.seasonPhase))).sorted(), id: \.self) { Text(verbatim: $0).tag($0) }
                }
                Picker("Week", selection: $filter.week) {
                    Text("All").tag(Int?.none)
                    ForEach(Array(Set(games.compactMap(\.fixture.week))).sorted(), id: \.self) { Text("Week \($0)").tag(Optional($0)) }
                }
                if filter.range == .custom {
                    #if os(tvOS)
                        SportsReplayDatePicker(title: "From", date: $customStart)
                        SportsReplayDatePicker(title: "To", date: $customEnd)
                    #else
                        DatePicker("From", selection: $customStart, displayedComponents: .date)
                        DatePicker("To", selection: $customEnd, displayedComponents: .date)
                    #endif
                }
            }
            .platformNavigationTitle("Filters")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingFilters = false } } }
        }
    }
}
