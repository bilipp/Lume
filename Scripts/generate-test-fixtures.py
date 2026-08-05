#!/usr/bin/env python3
"""Regenerate the ExampleData/ JSON fixtures used by DTO decoding tests.

Run from the repo root:
    python3 Scripts/generate-test-fixtures.py

Output goes to ExampleData/ (gitignored — each developer generates their own).
"""

import json
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(REPO, "ExampleData")


def write(name, obj):
    path = os.path.join(OUT, name)
    with open(path, "w") as f:
        json.dump(obj, f, indent=2)
    print(f"  {name}  ({len(obj)} items)" if isinstance(obj, list) else f"  {name}")


def main():
    os.makedirs(OUT, exist_ok=True)

    # 1. AccountInfo.json — XtreamAuthResponse
    write("AccountInfo.json", {
        "user_info": {
            "username": "1234567890",
            "password": "",
            "message": "",
            "auth": 1,
            "status": "Active",
            "exp_date": "1893456000",
            "is_trial": "0",
            "active_cons": "1",
            "created_at": "1700000000",
            "max_connections": "3",
            "allowed_output_formats": ["m3u8", "ts", "rtmp"],
        },
        "server_info": {
            "url": "example-iptv.com",
            "port": "8080",
            "https_port": "443",
            "server_protocol": "http",
            "rtmp_port": "1935",
            "timezone": "Europe/Berlin",
            "timestamp_now": 1735000000,
            "time_now": "2024-12-23 12:00:00",
        },
    })

    # 2. LiveCategories.json — 48 categories
    write("LiveCategories.json", [
        {"category_id": str(1300 + i), "category_name": f"Live Category {i+1}", "parent_id": 0}
        for i in range(48)
    ])

    # 3. MovieCategories.json — 27 categories (first: id "117", "Old movies")
    cats = [{"category_id": "117", "category_name": "Old movies", "parent_id": 0}]
    for i in range(1, 27):
        cats.append({"category_id": str(200 + i), "category_name": f"Movie Category {i+1}", "parent_id": 0})
    write("MovieCategories.json", cats)

    # 4. SeriesCategories.json — 19 categories
    write("SeriesCategories.json", [
        {"category_id": str(800 + i), "category_name": f"Series Category {i+1}", "parent_id": 0}
        for i in range(19)
    ])

    # 5. LiveStreams.json — 2568 entries (first: stream_id 1537280, category_id "1339")
    streams = []
    for i in range(2568):
        sid = 1537280 + i
        streams.append({
            "num": i + 1,
            "name": f"Live Channel {i+1}",
            "stream_type": "live",
            "stream_id": sid,
            "stream_icon": f"https://example.com/icons/{sid}.png",
            "epg_channel_id": f"channel_{sid}",
            "added": "1700000000",
            "is_adult": 0,
            "category_id": "1339" if i == 0 else str(1300 + (i % 48)),
            "custom_sid": "",
            "tv_archive": 0,
            "tv_archive_duration": 0,
        })
    write("LiveStreams.json", streams)

    # 6. Movies.json — 10001 entries (first: stream_id 2001952, "First movie", …)
    movies = []
    for i in range(10001):
        sid = 2001952 + i
        if i == 0:
            movies.append({
                "num": 1,
                "name": "First movie",
                "stream_type": "movie",
                "stream_id": sid,
                "stream_icon": f"https://example.com/movie_posters/{sid}.jpg",
                "rating": "6.406",
                "rating_5based": 3.2,
                "added": "1779391620",
                "is_adult": 0,
                "category_id": "117",
                "container_extension": "mkv",
                "tmdb": "582913",
            })
        elif i == 255:
            movies.append({
                "num": i + 1, "name": f"Movie {i+1}", "stream_type": "movie",
                "stream_id": sid, "stream_icon": f"https://example.com/movie_posters/{sid}.jpg",
                "rating": "6.5", "rating_5based": 3.25, "added": str(1700000000 + i),
                "is_adult": 0, "category_id": str(200 + (i % 27)),
                "container_extension": "mp4", "tmdb": "25641",
            })
        else:
            movies.append({
                "num": i + 1, "name": f"Movie {i+1}", "stream_type": "movie",
                "stream_id": sid, "stream_icon": f"https://example.com/movie_posters/{sid}.jpg",
                "rating": str(round(5.0 + (i % 50) / 10.0, 2)),
                "rating_5based": round(2.5 + (i % 40) / 20.0, 1),
                "added": str(1700000000 + i), "is_adult": 0,
                "category_id": str(200 + (i % 27)),
                "container_extension": "mp4" if i % 2 == 0 else "mkv",
                "tmdb": str(100000 + i),
            })
    write("Movies.json", movies)

    # 7. MovieInfo.json — XtreamVODInfo
    write("MovieInfo.json", {
        "info": {
            "tmdb_id": "672",
            "name": "Harry Potter and the Chamber of Secrets",
            "movie_image": "https://image.tmdb.org/t/p/w500/example.jpg",
            "releasedate": "2002-11-13",
            "duration_secs": 9660,
            "youtube_trailer": "https://www.youtube.com/watch?v=example",
            "director": "Chris Columbus, Peter MacDonald, David Hanks, Annie Penn, Chris Carreras",
            "actors": "Daniel Radcliffe, Emma Watson, Rupert Grint",
            "description": "Description text",
            "plot": "Plot text",
            "genre": "Adventure, Family, Fantasy",
        },
        "movie_data": {
            "stream_id": 535312,
            "name": "Harry Potter and the Chamber of Secrets",
            "num": 1, "stream_type": "movie", "container_extension": "mkv",
            "category_id": "117", "added": "1700000000", "rating": "7.6",
            "rating_5based": 3.8, "is_adult": 0, "tmdb": "672",
        },
    })

    # 8. Series.json — 2215 entries (first: series_id 46567, "First series", category_id "817")
    series = []
    for i in range(2215):
        sid = 46567 + i
        if i == 0:
            series.append({
                "num": 1, "name": "First series", "series_id": sid,
                "cover": f"https://example.com/covers/{sid}.jpg",
                "plot": f"Plot", "cast": "Actor A, Actor B", "director": "Director X",
                "genre": "Drama", "releaseDate": "2024-01-01", "last_modified": "1700000000",
                "rating": "8", "rating_5based": "4.0", "category_id": "817", "tmdb": "100001",
            })
        elif i == 97:
            series.append({
                "num": i + 1, "name": f"Series {i+1}", "series_id": 46565,
                "cover": f"https://example.com/covers/{sid}.jpg",
                "plot": f"Plot", "cast": "Actor A", "director": "Director X",
                "genre": "Drama", "releaseDate": "2024-01-01", "last_modified": "1700000000",
                "rating": "8", "rating_5based": "4.0", "category_id": "209", "tmdb": "278113",
            })
        else:
            series.append({
                "num": i + 1, "name": f"Series {i+1}", "series_id": sid,
                "cover": f"https://example.com/covers/{sid}.jpg",
                "plot": f"Plot", "cast": "Actor A", "director": "Director X",
                "genre": "Drama", "releaseDate": "2024-01-01", "last_modified": "1700000000",
                "rating": str(round(6.0 + (i % 40) / 10.0, 1)),
                "rating_5based": str(round(3.0 + (i % 30) / 10.0, 1)),
                "category_id": str(800 + (i % 27)),
                "tmdb": str(100000 + i),
            })
    write("Series.json", series)

    # 9. SeriesInfo.json — XtreamSeriesInfoResponse (Breaking Bad, 2 seasons)
    write("SeriesInfo.json", {
        "info": {
            "name": "Breaking Bad", "tmdb": "1396",
            "cover": "https://image.tmdb.org/t/p/w500/example.jpg",
            "plot": "A chemistry teacher turns to manufacturing methamphetamine.",
            "cast": "Bryan Cranston, Aaron Paul", "director": "Vince Gilligan",
            "genre": "Crime, Drama", "releaseDate": "2008-01-20",
            "last_modified": "1700000000", "rating": "9.5",
        },
        "episodes": {
            "1": [
                {
                    "id": "129902", "episode_num": 1, "season": 1,
                    "title": "Breaking Bad - S01E01", "container_extension": "mp4",
                    "info": {
                        "air_date": "2008-01-20", "duration_secs": 3486,
                        "rating": 7.826,
                        "movie_image": "https://image.tmdb.org/t/p/w500/example.jpg",
                        "plot": "Pilot",
                    },
                }
                for _ in range(7)
            ],
            "2": [
                {
                    "id": str(130001 + j), "episode_num": j + 1, "season": 2,
                    "title": f"Breaking Bad - S02E{j+1:02d}", "container_extension": "mp4",
                    "info": {
                        "air_date": f"2009-0{(j+8)//10:1d}{(j+8)%10+1:1d}",
                        "duration_secs": 3480, "rating": round(7.5 + j * 0.05, 1),
                        "movie_image": "https://image.tmdb.org/t/p/w500/example.jpg",
                        "plot": f"Episode {j+1}",
                    },
                }
                for j in range(13)
            ],
        },
    })

    print(f"\nDone — {OUT}/ has 9 files.")


if __name__ == "__main__":
    main()
