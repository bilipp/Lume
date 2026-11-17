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

    private var filtered: [SportsReplayGame] {
        var filter = filter
        filter.custom = customDates
        filter.followedTeamIDs = Set(follows.followedTeamIds)
        return filter.apply(games)
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
                    if filtered.isEmpty {
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
                    if filter.range == .recent {
                        Button("Load older") { filter.recentDays += 14 }
                            .frame(minHeight: 44)
                    }
                }
                .padding()
            }
        }
        .sheet(isPresented: $showingFilters) { filters }
        .sheet(item: $selected, onDismiss: { progressRevision += 1 }, content: { SportsReplayDetail(game: $0) })
        .onChange(of: filter.range) { _, value in if value == .custom { showingFilters = true } }
    }

    @ViewBuilder
    private var continueWatching: some View {
        let namespace = RecordingServerConfigService.shared.activeServer?.progressNamespace
        let continuing = filtered.filter { game in
            game.recordings.contains { RecordingProgressStore.resumePosition(for: $0, namespace: namespace) > 0 }
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
