# Lume - the IPTV player for iOS, tvOS and macOS

## General
Lume is an IPTV player for iOS, tvOS and macOS. It supports xtream playlists, EPG data, and various streaming formats. Lume is built using SwiftUI, SwiftData and KSPlayer, providing a modern and intuitive user interface.


## Features
- Xtream playlist support
- EPG data display
- Multiple streaming format support (HLS, DASH, etc.)
- User-friendly interface (SwiftUI)
- Cross-platform support (iOS, tvOS, macOS)
- Customizable player settings (aspect ratio, subtitles, etc.)

## Layout

### General
- The app has a clean and modern design, following the latest SwiftUI design patterns and best practices
- Tab-based navigation with sections for Home (future), Live TV, Movies, TV Shows and search (search icon separated according to latest SwiftUI design patterns). On scroll, the tab bar will shrink to only the active tab icon, and the search icon will be always visible on the right side of the screen (latest SwiftUI design patterns).
- Each section will have its own view
- Settings in the top right corner
- User profile (future) in the top left corner
- Title of the active section in the top center of the screen

### Home Screen (Todo - will be added in the future)
(collection of ideas - not finalized yet)
- Default section in the future
- Recently watched content (movies, TV shows, channels)
- Personalized recommendations based on watch history and preferences
- Trending movies and TV shows (tmdb or similar integration)
- Watchlist and favorites
- Quick access to live TV channels

### Live TV (Todo - will be added in the future)
(collection of ideas - not finalized yet)
- Recently watched channels
- Favorite channels
- Channel categories (from playlist). On click, the category will be opend and all channels will be shown with channel logo, name and EPG data (current and next show). On click on a channel, the player will be opened and the stream will start playing.

### Movies
- Sections for different categories (continue watching, trending, recently added, etc.)
- Each section will have a horizontal scrollable list of movies with their poster - resulting in a clean look.
- On click on a movie, the movie details view will be opened

### TV Shows
- Features similar to the movies
- Within a show, the user will be able to select the season and episode

#### Movie / Show Details
- Showing the movie or show poster, title, description, rating, etc. 
- A play button to start playing the movie or show
- On play, the app will check, if the movie or show is available in the xtream playlist, and if it is, the stream will start playing. If the movie or show is not available in the xtream playlist, a message will be shown to the user. If multiple streams are available, the user will be able to choose which stream to play (different qualities, etc.). The movie or show details view will also have a section for related movies or shows (similar movies or shows based on genre, etc.) and a section for recommended movies or shows (based on watch history, etc. - future feature).
- For shows: Selection of season and episode, with the same features as movies (checking availability in the xtream playlist, etc.)

### Settings
In the settings, users will be able to manage their xtream playlist (credentials and other information from the server information like active connections and expiration date), customize player settings (aspect ratio, subtitles, etc.), manage their content (refresh interval, hide/show categories, reorder categories or channels, etc.) and customize the appearance of the app (dark mode, etc.).

## Content indexing
The app will index the content from the xtream playlist and EPG data, allowing for fast and efficient searching and browsing. The indexed data will be stored locally on the device using SwiftData, providing offline access to the content.
This also includes the ability to hide / show specific categories or channels, and reorder them according to user preferences.
Additionally, the indexing enables features like progression tracking, watch history, personalized recommendations, etc. in the future.

## Future Plans
There are a lot of ideas for the future of the app, but the main focus will be on improving the user experience, adding new features and optimizing performance. Some of the planned features include the following.

### Features
- [ ] Live TV support with EPG data display, channel logos, etc.
- [ ] Home screen with trending movies and TV shows, personalized recommendations, history, etc.
- [ ] Progression tracking (resume watching, watch history, etc.)
- [ ] Trakt integration (progression tracking, watch history, rating, collections, etc.)
- [ ] Trending movies and TV shows (tmdb or similar integration)
- [ ] Recommendations based on watch history (vector based recommendation engine - tbd what is possible to implement on device - maybe Apple Intelligence framework can be used)
- [ ] User profiles (multiple users, auto login, etc.)
- [ ] Watchlist and favorites
- [ ] Downloads / Offline viewing (with settings to limit simultaneous downloads, auto delete after watching, etc.)

### Enhancements / Settings
- [ ] iCloud sync for user data (settings, playlist information, watch history, watchlist, favorites, etc.)
- [ ] m3u support
- [ ] Genre categorization for movies and TV shows
- [ ] Multiple players support (AVPlayer, VLC, etc.) with automatic fallback and preference settings (separate settings for live TV and movies/TV shows)
- [ ] Ratings on single views (IMDB, Rotten Tomatoes, etc.)
- [ ] Parental controls
- [ ] Airplay / Chromecast support (depends on player engine support)
- [ ] Picture-in-picture mode
- [ ] Option to hide content (categories or specific channels)
- [ ] Custom EPG sources

## Xtream Codes API Documentation
For more information on the Xtream Codes API, please refer to the [Xtream Codes API Documentation](XtreamAPI.md) file, which provides detailed information on the available endpoints, authentication, and response formats for retrieving server information, live streams, video-on-demand content, series, and EPG data.