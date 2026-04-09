# Xtream Codes API Documentation

## Overview

The Xtream Codes API provides endpoints for IPTV clients to retrieve server information, live streams, video-on-demand (VOD) content, series, and Electronic Program Guide (EPG) data.

## Base Endpoints & Authentication

All API requests require user authentication via query parameters.

**Base Paths:**

- JSON API: `/player_api.php`
- XMLTV (EPG): `/xmltv.php`
- M3U Playlist: `/get.php`

**Authentication Parameters:**
All requests to `player_api.php` must include the following query parameters:

- `username` (string): Your account username.
- `password` (string): Your account password.

---

## 1. General & Account Information

### Get Server and User Info

Retrieves general server details and the status of the current user account.

- **Endpoint:** `/player_api.php`
- **Method:** `GET`
- **Query Parameters:** `username`, `password`
- **Response:**
  - `user_info`: User status, expiration date, active connections, allowed connections, trial status.
  - `server_info`: Server URL, port, timezone, RTMP port, and protocol.
- **Example Response:**

```json
{
  "user_info": {
    "username": "username",
    "password": "password",
    "message": "Welcome!",
    "auth": 1,
    "status": "Active",
    "exp_date": "1776026254",
    "is_trial": "0",
    "active_cons": "0",
    "created_at": "1736631454",
    "max_connections": "1",
    "allowed_output_formats": ["m3u8", "ts"]
  },
  "server_info": {
    "url": "example.com",
    "port": "8080",
    "https_port": "443",
    "server_protocol": "http",
    "rtmp_port": "25462",
    "timezone": "Europe/Berlin",
    "timestamp_now": 1775758163,
    "time_now": "2026-04-09 20:09:23",
    "process": true
  }
}
```

---

## 2. Live TV (IPTV)

### Get Live Categories

Retrieves all available Live TV categories.

- **Endpoint:** `/player_api.php?action=get_live_categories`
- **Method:** `GET`
- **Response:** A list of category objects (`category_id`, `category_name`, `parent_id`).
- **Example Response:**

```json
[
  {
    "category_id": "1",
    "category_name": "News",
    "parent_id": 0
  },
  {
    "category_id": "2",
    "category_name": "Sports",
    "parent_id": 0
  }
]
```

### Get Live Streams

Retrieves all live TV channels. You can filter by category.

- **Endpoint:** `/player_api.php?action=get_live_streams`
- **Method:** `GET`
- **Optional Query Parameter:** `category_id` (Returns streams only for the specified category).
- **Response:** List of `LiveStreamItem` objects containing:
  - `stream_id` (int)
  - `name` (string)
  - `stream_type` (string - typically "live")
  - `stream_icon` (string - URL)
  - `epg_channel_id` (string)
  - `category_id` (int or string)
  - `tv_archive` (int - indicates if catchup is available)
  - `tv_archive_duration` (int - catchup duration in days)
- **Example Response:**

```json
[
  {
    "num": 1,
    "name": "↺ARD FHD",
    "stream_type": "live",
    "stream_id": 154591,
    "stream_icon": "https://example.com/logo/germany/ard-1de.png",
    "epg_channel_id": "ard.de",
    "added": "1628021117",
    "is_adult": 0,
    "category_id": "222",
    "category_ids": [222],
    "custom_sid": null,
    "tv_archive": 1,
    "direct_source": "",
    "tv_archive_duration": "3"
  },
  {
    "num": 2,
    "name": "ARD HD",
    "stream_type": "live",
    "stream_id": 95550,
    "stream_icon": "https://example.com/logo/germany/ard-1de.png",
    "epg_channel_id": "ard.de",
    "added": "1606471083",
    "is_adult": 0,
    "category_id": "222",
    "category_ids": [222],
    "custom_sid": null,
    "tv_archive": 0,
    "direct_source": "",
    "tv_archive_duration": 0
  },
  {
    "num": 3,
    "name": "↺ZDF FHD",
    "stream_type": "live",
    "stream_id": 95552,
    "stream_icon": "https://example.com/logo/germany/Zdff.png",
    "epg_channel_id": "zdf.de",
    "added": "1606471083",
    "is_adult": 0,
    "category_id": "222",
    "category_ids": [222],
    "custom_sid": null,
    "tv_archive": 1,
    "direct_source": "",
    "tv_archive_duration": "3"
  }
]
```

---

## 3. Video On Demand (VOD / Movies)

### Get VOD Categories

Retrieves all available VOD categories.

- **Endpoint:** `/player_api.php?action=get_vod_categories`
- **Method:** `GET`
- **Response:** List of VOD category objects.
- **Example Response:**

```json
[
  {
    "category_id": "1",
    "category_name": "Action",
    "parent_id": 0
  },
  {
    "category_id": "2",
    "category_name": "Comedy",
    "parent_id": 0
  }
]
```

### Get VOD Streams

Retrieves all movies/VODs. You can filter by category.

- **Endpoint:** `/player_api.php?action=get_vod_streams`
- **Method:** `GET`
- **Optional Query Parameter:** `category_id`
- **Response:** List of `VodItem` objects containing:
  - `stream_id` (int)
  - `name` (string)
  - `stream_icon` (string)
  - `container_extension` (string - e.g., mp4, mkv)
  - `rating` (double)
  - `added` (timestamp)
- **Example Response:**

```json
[
  {
    "num": 1,
    "name": "Mufasa: Der König der Löwen (2024)",
    "stream_type": "movie",
    "stream_id": 902992,
    "stream_icon": "https://image.tmdb.org/t/p/w600_and_h900_bestv2/1NArKlcharcFrynRlqn5zQRXeXN.jpg",
    "rating": "7.308",
    "rating_5based": 3.7,
    "tmdb": "762509",
    "trailer": "2_pdEO8I06c",
    "added": "1775488800",
    "is_adult": 0,
    "category_id": "370",
    "category_ids": [370],
    "container_extension": "mkv",
    "custom_sid": null,
    "direct_source": ""
  },
  {
    "num": 2,
    "name": "Æon Flux - 2005",
    "stream_type": "movie",
    "stream_id": 901424,
    "stream_icon": "https://image.tmdb.org/t/p/w600_and_h900_bestv2/eqqV7NmGBGej7EfCdyStg4YpXa9.jpg",
    "rating": "5.6",
    "rating_5based": 2.8,
    "tmdb": 8202,
    "trailer": "",
    "added": "1775431713",
    "is_adult": 0,
    "category_id": "370",
    "category_ids": [370],
    "container_extension": "mkv",
    "custom_sid": null,
    "direct_source": ""
  },
  {
    "num": 3,
    "name": "infinity - 2019",
    "stream_type": "movie",
    "stream_id": 901423,
    "stream_icon": "https://image.tmdb.org/t/p/w600_and_h900_bestv2/j9PP7o5mdBBYSrNR7W4drelS1ZU.jpg",
    "rating": "0",
    "rating_5based": 0,
    "tmdb": 664882,
    "trailer": "",
    "added": "1775431713",
    "is_adult": 0,
    "category_id": "370",
    "category_ids": [370],
    "container_extension": "mp4",
    "custom_sid": null,
    "direct_source": ""
  }
]
```

### Get VOD Info

Retrieves detailed metadata for a specific VOD (IMDb data, actors, director, plot, media info).

- **Endpoint:** `/player_api.php?action=get_vod_info`
- **Method:** `GET`
- **Required Query Parameter:** `vod_id` (The `stream_id` of the movie)
- **Response:** - `info`: Extensive metadata (plot, cast, director, genre, release date, runtime, cover image).
  - `movie_data`: Container extension and stream details.
- **Example Response:**

```json
{
  "info": {
    "kinopoisk_url": "https://www.themoviedb.org/movie/762509",
    "tmdb_id": "762509",
    "name": "Mufasa: Der König der Löwen (2024)",
    "o_name": "Mufasa: Der König der Löwen (2024)",
    "movie_image": "https://image.tmdb.org/t/p/w600_and_h900_bestv2/1NArKlcharcFrynRlqn5zQRXeXN.jpg",
    "releasedate": "2024-12-18",
    "episode_run_time": 118,
    "youtube_trailer": "2_pdEO8I06c",
    "director": "Barry Jenkins",
    "actors": "Aaron Pierre, Kelvin Harrison Jr., Tiffany Boone, Kagiso Lediga, Preston Nyman, Blue Ivy Carter, John Kani, Mads Mikkelsen, Seth Rogen, Billy Eichner",
    "cast": "Aaron Pierre, Kelvin Harrison Jr., Tiffany Boone, Kagiso Lediga, Preston Nyman, Blue Ivy Carter, John Kani, Mads Mikkelsen, Seth Rogen, Billy Eichner",
    "description": "Der verwaiste Mufasa ist verloren und allein, bis er auf Taka, den Erben einer königlichen Blutlinie, trifft. Dies ist der Beginn einer sagenhaften Reise, welche die Verbundenheit der beiden auf die Probe stellt, als sie sich einem tödlichen Feind gegenübersehen.",
    "plot": "Der verwaiste Mufasa ist verloren und allein, bis er auf Taka, den Erben einer königlichen Blutlinie, trifft. Dies ist der Beginn einer sagenhaften Reise, welche die Verbundenheit der beiden auf die Probe stellt, als sie sich einem tödlichen Feind gegenübersehen.",
    "age": "",
    "country": "English",
    "genre": "Abenteuer, Familie, Animation",
    "backdrop_path": [
      "https://image.tmdb.org/t/p/w1280/1w8kutrRucTd3wlYyu5QlUDMiG1.jpg"
    ],
    "duration_secs": "118",
    "duration": "01:58:00",
    "bitrate": 0,
    "rating": "7.308",
    "runtime": "118",
    "status": "Released"
  },
  "movie_data": {
    "stream_id": 902992,
    "name": "Mufasa: Der König der Löwen (2024)",
    "added": "1775488800",
    "category_id": "370",
    "category_ids": [370],
    "container_extension": "mkv",
    "custom_sid": null,
    "direct_source": ""
  }
}
```

---

## 4. TV Series

### Get Series Categories

Retrieves all available TV Series categories.

- **Endpoint:** `/player_api.php?action=get_series_categories`
- **Method:** `GET`
- **Response:** List of Series category objects.
- **Example Response:**

```json
[
  {
    "category_id": "1",
    "category_name": "Action",
    "parent_id": 0
  },
  {
    "category_id": "2",
    "category_name": "Comedy",
    "parent_id": 0
  }
]
```

### Get Series

Retrieves the list of available series.

- **Endpoint:** `/player_api.php?action=get_series`
- **Method:** `GET`
- **Optional Query Parameter:** `category_id`
- **Response:** List of `SeriesItem` objects containing:
  - `series_id` (int)
  - `name` (string)
  - `cover` (string - URL)
  - `plot` (string)
  - `cast`, `director`, `genre`, `releaseDate`, `rating`
  - `category_id` (int)
- **Example Response:**

```json
[
  {
    "num": 1,
    "name": "Stranger Things (2016)",
    "series_id": 17404,
    "cover": "https://image.tmdb.org/t/p/w600_and_h900_bestv2/uOOtwVbSr4QDjAGIifLDwpb2Pdl.jpg",
    "plot": "Nach dem Verschwinden eines Jungen treten in einer Kleinstadt geheime Regierungsexperimente, übernatürliche Kräfte und ein merkwürdiges kleines Mädchen zutage.",
    "cast": "Millie Bobby Brown, Finn Wolfhard, Gaten Matarazzo, Caleb McLaughlin, Sadie Sink, David Harbour, Winona Ryder, Natalia Dyer",
    "director": "Ross Duffer, Matt Duffer",
    "genre": "Drama / Sci-Fi & Fantasy / Mystery",
    "releaseDate": "2016-07-15",
    "release_date": "2016-07-15",
    "last_modified": "1767431933",
    "rating": "9",
    "rating_5based": "4.5",
    "backdrop_path": [
      "https://image.tmdb.org/t/p/w1280/56v2KjBlU4XaOv9rVYEQypROD7P.jpg",
      "https://image.tmdb.org/t/p/w1280/8zbAoryWbtH0DKdev8abFAjdufy.jpg",
      "https://image.tmdb.org/t/p/w1280/hTWtybOC91veCgHAVt3ULZnj4up.jpg",
      "https://image.tmdb.org/t/p/w1280/2MaumbgBlW1NoPo3ZJO38A6v7OS.jpg",
      "https://image.tmdb.org/t/p/w1280/rcA17r3hfHtRrk3Xs3hXrgGeSGT.jpg"
    ],
    "youtube_trailer": "mnd7sFt5c3A",
    "tmdb": "66732",
    "episode_run_time": "0",
    "category_id": "38",
    "category_ids": [38]
  },
  {
    "num": 2,
    "name": "Breaking Bad (2008)",
    "series_id": 17396,
    "cover": "https://image.tmdb.org/t/p/w600_and_h900_bestv2/u1N5AQ0T6Xr28bZGP84AcSJ5M6b.jpg",
    "plot": "Ein krebskranker Chemielehrer tut sich mit einem ehemaligen Schüler zusammen, um die Zukunft seiner Familie durch die Herstellung und den Verkauf von Meth zu sichern.",
    "cast": "Bryan Cranston, Aaron Paul, Anna Gunn, RJ Mitte, Dean Norris, Betsy Brandt, Bob Odenkirk, Jonathan Banks",
    "director": "Vince Gilligan",
    "genre": "Drama / Krimi",
    "releaseDate": "2008-01-20",
    "release_date": "2008-01-20",
    "last_modified": "1759664107",
    "rating": "9",
    "rating_5based": "4.5",
    "backdrop_path": [
      "https://image.tmdb.org/t/p/w1280/tsRy63Mu5cu8etL1X7ZLyf7UP1M.jpg",
      "https://image.tmdb.org/t/p/w1280/EurcYIB7obJgoVzeui2RZkFlEm.jpg",
      "https://image.tmdb.org/t/p/w1280/yXSzo0VU1Q1QaB7Xg5Hqe4tXXA3.jpg",
      "https://image.tmdb.org/t/p/w1280/9faGSFi5jam6pDWGNd0p8JcJgXQ.jpg",
      "https://image.tmdb.org/t/p/w1280/gc8PfyTqzqltKPW3X0cIVUGmagz.jpg"
    ],
    "youtube_trailer": "XZ8daibM3AE",
    "tmdb": "1396",
    "episode_run_time": "0",
    "category_id": "38",
    "category_ids": [38]
  }
]
```

### Get Series Info

Retrieves metadata for a series, along with a list of seasons and episodes.

- **Endpoint:** `/player_api.php?action=get_series_info`
- **Method:** `GET`
- **Required Query Parameter:** `series_id`
- **Response:**
  - `info`: Detailed series metadata.
  - `episodes`: A map/dictionary of episodes categorized by season number.
  - `seasons`: Array of season objects detailing cover images and episode counts.
- **Example Response:**

```json
{
  "seasons": [],
  "info": {
    "name": "Stranger Things (2016)",
    "cover": "https://image.tmdb.org/t/p/w600_and_h900_bestv2/uOOtwVbSr4QDjAGIifLDwpb2Pdl.jpg",
    "plot": "Nach dem Verschwinden eines Jungen treten in einer Kleinstadt geheime Regierungsexperimente, übernatürliche Kräfte und ein merkwürdiges kleines Mädchen zutage.",
    "cast": "Millie Bobby Brown, Finn Wolfhard, Gaten Matarazzo, Caleb McLaughlin, Sadie Sink, David Harbour, Winona Ryder, Natalia Dyer",
    "director": "Ross Duffer, Matt Duffer",
    "genre": "Drama / Sci-Fi & Fantasy / Mystery",
    "releaseDate": "2016-07-15",
    "release_date": "2016-07-15",
    "last_modified": "1767431933",
    "rating": "9",
    "rating_5based": "4.5",
    "backdrop_path": [
      "https://image.tmdb.org/t/p/w1280/56v2KjBlU4XaOv9rVYEQypROD7P.jpg",
      "https://image.tmdb.org/t/p/w1280/8zbAoryWbtH0DKdev8abFAjdufy.jpg",
      "https://image.tmdb.org/t/p/w1280/hTWtybOC91veCgHAVt3ULZnj4up.jpg",
      "https://image.tmdb.org/t/p/w1280/2MaumbgBlW1NoPo3ZJO38A6v7OS.jpg",
      "https://image.tmdb.org/t/p/w1280/rcA17r3hfHtRrk3Xs3hXrgGeSGT.jpg"
    ],
    "tmdb": "66732",
    "youtube_trailer": "mnd7sFt5c3A",
    "episode_run_time": "0",
    "category_id": "38",
    "category_ids": [
      38
    ]
  },
  "episodes": {
    "1": [
      {
        "id": "688951",
        "episode_num": 1,
        "title": "Stranger Things (2016) - S01E01 - Kapitel eins: Das Verschwinden des Will Byers",
        "container_extension": "mkv",
        "info": {
          "air_date": "2016-07-15",
          "crew": "Ross Duffer, Matt Duffer, Matt Duffer, Ross Duffer, Tim Ives",
          "rating": 8.473,
          "id": 66732,
          "movie_image": "https://image.tmdb.org/t/p/w185/uLES7sRpy7Ih6Kr6XCaYj1GyfTw.jpg",
          "duration_secs": 2903,
          "duration": "00:48:23",
          "video": {
            "index": 0,
            "codec_name": "hevc",
            "codec_long_name": "unknown",
            "profile": "1",
            "codec_type": "video",
            "codec_tag_string": "[0][0][0][0]",
            "codec_tag": "0x0000",
            "width": 1920,
            "height": 960,
            "coded_width": 1920,
            "coded_height": 960,
            "closed_captions": 0,
            "film_grain": 0,
            "has_b_frames": 2,
            "sample_aspect_ratio": "1:1",
            "display_aspect_ratio": "2:1",
            "pix_fmt": "yuv420p",
            "level": 120,
            "color_range": "tv",
            "color_space": "bt709",
            "color_transfer": "bt709",
            "color_primaries": "bt709",
            "chroma_location": "left",
            "refs": 1,
            "r_frame_rate": "24000/1001",
            "avg_frame_rate": "24000/1001",
            "time_base": "1/1000",
            "start_pts": 5,
            "start_time": "0.005000",
            "extradata_size": 2109,
            "disposition": {
              "default": 1,
              "dub": 0,
              "original": 0,
              "comment": 0,
              "lyrics": 0,
              "karaoke": 0,
              "forced": 0,
              "hearing_impaired": 0,
              "visual_impaired": 0,
              "clean_effects": 0,
              "attached_pic": 0,
              "timed_thumbnails": 0,
              "captions": 0,
              "descriptions": 0,
              "metadata": 0,
              "dependent": 0,
              "still_image": 0
            },
            "tags": {
              "BPS-eng": "1968665",
              "DURATION-eng": "00:48:23.276000000",
              "NUMBER_OF_FRAMES-eng": "69609",
              "NUMBER_OF_BYTES-eng": "714447388",
              "_STATISTICS_WRITING_APP-eng": "mkvmerge v46.0.0 ('No Deeper Escape') 64-bit",
              "_STATISTICS_WRITING_DATE_UTC-eng": "2020-05-20 15:32:39",
              "_STATISTICS_TAGS-eng": "BPS DURATION NUMBER_OF_FRAMES NUMBER_OF_BYTES"
            }
          },
          "audio": {
            "index": 2,
            "codec_name": "ac3",
            "codec_long_name": "unknown",
            "codec_type": "audio",
            "codec_tag_string": "[0][0][0][0]",
            "codec_tag": "0x0000",
            "sample_fmt": "fltp",
            "sample_rate": "48000",
            "channels": 6,
            "channel_layout": "5.1(side)",
            "bits_per_sample": 0,
            "r_frame_rate": "0/0",
            "avg_frame_rate": "0/0",
            "time_base": "1/1000",
            "start_pts": 0,
            "start_time": "0.000000",
            "bit_rate": "384000",
            "disposition": {
              "default": 0,
              "dub": 0,
              "original": 0,
              "comment": 0,
              "lyrics": 0,
              "karaoke": 0,
              "forced": 0,
              "hearing_impaired": 0,
              "visual_impaired": 0,
              "clean_effects": 0,
              "attached_pic": 0,
              "timed_thumbnails": 0,
              "captions": 0,
              "descriptions": 0,
              "metadata": 0,
              "dependent": 0,
              "still_image": 0
            },
            "tags": {
              "language": "eng",
              "title": "Surround",
              "BPS-eng": "384000",
              "DURATION-eng": "00:48:23.456000000",
              "NUMBER_OF_FRAMES-eng": "90733",
              "NUMBER_OF_BYTES-eng": "139365888",
              "_STATISTICS_WRITING_APP-eng": "mkvmerge v46.0.0 ('No Deeper Escape') 64-bit",
              "_STATISTICS_WRITING_DATE_UTC-eng": "2020-05-20 15:32:39",
              "_STATISTICS_TAGS-eng": "BPS DURATION NUMBER_OF_FRAMES NUMBER_OF_BYTES"
            }
          },
          "bitrate": 2739
        },
        "custom_sid": null,
        "added": "1754375179",
        "season": 1,
        "direct_source": ""
      },
      ... (more episodes in season 1)
    ],
    ... (more seasons)
  }
}
```

---

## 5. Electronic Program Guide (EPG)

### Get Complete XMLTV (Full EPG)

Downloads the entire EPG for all channels in XMLTV format.

- **Endpoint:** `/xmltv.php`
- **Method:** `GET`
- **Query Parameters:** `username`, `password`
- **Response:** XML file containing full programming data.

### Get Short EPG (Channel Specific)

Retrieves the timeline of programs for a specific live channel.

- **Endpoint:** `/player_api.php?action=get_short_epg`
- **Method:** `GET`
- **Required Query Parameters:** - `stream_id`: The ID of the live TV stream.
  - `limit`: (Optional) Number of listings to retrieve (e.g., 10).
- **Response:** List of `EpgListing` objects containing `start`, `end`, `title`, and `description`.

---

## 6. Playback & Streaming URLs

Though not standard REST JSON API endpoints, playback is achieved by constructing specific URLs based on the retrieved `stream_id` and `container_extension`.

**Live TV Playback:**

```text
http://{server_url}:{port}/{username}/{password}/{stream_id}
```

_(Optionally append `.m3u8` or `.ts` depending on the required stream format)._

**VOD (Movie) Playback:**

```text
http://{server_url}:{port}/movie/{username}/{password}/{stream_id}.{container_extension}
```

**Series (Episode) Playback:**

```text
http://{server_url}:{port}/series/{username}/{password}/{episode_stream_id}.{container_extension}
```

---

## Error Handling

The Xtream Codes API typically handles errors in two ways depending on the server configuration:

1. **HTTP Status Codes:** `401 Unauthorized` or `403 Forbidden` if authentication fails or an account is expired.
2. **Empty Bodies / Null Returns:** In case an `action` is invalid or empty datasets are queried, the server might return an empty JSON object `{}` or `null` rather than a standard HTTP error. (The `xtream_code_client` handles this gracefully via lenient parsing modes).
