import SwiftData
import SwiftUI

#Preview("Basic") {
    let container = previewContainer()
    let series = PreviewData.sampleSeries
    return NavigationStack {
        SeriesDetailView(series: series)
    }
    .modelContainer(container)
}

#Preview("With TMDB + Episodes") {
    let container = previewContainer()
    let series = PreviewData.sampleSeries
    series.backdropPath = "/abc123backdrop.jpg"
    series.tagline = "I am the one who knocks."
    series.contentRating = "TV-MA"
    series.tmdbId = 1396
    series.tmdb = "1396"
    series.tmdbEnrichedAt = Date().addingTimeInterval(-3600)
    series.isFavorite = true
    return NavigationStack {
        SeriesDetailView(series: series)
    }
    .modelContainer(container)
}

#Preview("No TMDB") {
    let container = previewContainer()
    let series = PreviewData.sampleSeries
    series.plot = nil
    series.genre = nil
    series.director = nil
    return NavigationStack {
        SeriesDetailView(series: series)
    }
    .modelContainer(container)
}

#Preview("Favorite") {
    let container = previewContainer()
    let series = PreviewData.sampleSeries
    series.backdropPath = "/abc123backdrop.jpg"
    series.tagline = "I am the one who knocks."
    series.tmdbId = 1396
    series.isFavorite = true
    return NavigationStack {
        SeriesDetailView(series: series)
    }
    .modelContainer(container)
}
