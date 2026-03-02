"""Last.fm scrobbling and now-playing integration via pylast."""

import logging
import re
import time
from datetime import datetime, timezone

import pylast

from needledrop.config import NeedleDropConfig, ScrobbleFilters
from needledrop.database.models import Scrobble
from needledrop.database.stats import is_duplicate_scrobble

from sqlalchemy.orm import Session, sessionmaker

log = logging.getLogger(__name__)


class CompiledFilters:
    """Pre-compiled regex patterns for track filtering."""

    def __init__(self, filters: ScrobbleFilters):
        self.min_duration = filters.min_duration
        self.artist_patterns: list[re.Pattern[str]] = [
            re.compile(p) for p in filters.artist_exclude
        ]
        self.title_patterns: list[re.Pattern[str]] = [
            re.compile(p) for p in filters.title_exclude
        ]


class LastFMScrobbler:
    """Wraps pylast for scrobbling, now-playing, and track filtering."""

    def __init__(self, config: NeedleDropConfig, session_factory: sessionmaker[Session]):
        self.network = pylast.LastFMNetwork(
            api_key=config.lastfm.api_key,
            api_secret=config.lastfm.api_secret,
            username=config.lastfm.username,
            password_hash=config.lastfm.password_hash,
        )
        self._session_factory = session_factory
        self._filters = CompiledFilters(config.scrobble.filters)

    def should_filter(self, artist: str, title: str, duration: int) -> bool:
        """Check if a track should be excluded from scrobbling.

        Args:
            artist: Artist name.
            title: Track title.
            duration: Track duration in seconds.

        Returns:
            True if the track should be filtered out.
        """
        artist = artist.strip()
        title = title.strip()

        for pattern in self._filters.artist_patterns:
            if pattern.search(artist):
                log.info("Filtered: artist '%s' matched pattern '%s'", artist, pattern.pattern)
                return True

        for pattern in self._filters.title_patterns:
            if pattern.search(title):
                log.info("Filtered: title '%s' matched pattern '%s'", title, pattern.pattern)
                return True

        if 0 < duration < self._filters.min_duration:
            log.info("Filtered: track too short (%ds) - %s - %s", duration, artist, title)
            return True

        return False

    def scrobble(
        self,
        artist: str,
        title: str,
        album: str | None,
        album_artist: str | None,
        duration: int,
        zone_name: str | None,
    ) -> bool:
        """Scrobble a track to last.fm and record it in the database.

        Args:
            artist: Artist name.
            title: Track title.
            album: Album name.
            album_artist: Album artist name.
            duration: Track duration in seconds.
            zone_name: Sonos zone that played the track.

        Returns:
            True if the scrobble was recorded, False if filtered/duplicate.
        """
        if self.should_filter(artist, title, duration):
            return False

        with self._session_factory() as session:
            if is_duplicate_scrobble(session, artist, title):
                log.debug("Skipped duplicate: %s - %s", artist, title)
                return False

            synced = False
            try:
                self.network.scrobble(
                    artist=artist,
                    title=title,
                    timestamp=int(time.time()),
                    album=album or "",
                )
                synced = True
                log.info("Scrobbled: %s - %s", artist, title)
            except (pylast.NetworkError, pylast.MalformedResponseError) as e:
                log.error("Last.fm network error, saving locally: %s", e)
            except pylast.WSError as e:
                log.error("Last.fm API error: %s", e)
                # Don't persist on validation errors (e.g. invalid track)
                return False

            scrobble = Scrobble(
                artist=artist,
                track=title,
                album=album,
                album_artist=album_artist,
                duration_seconds=duration,
                scrobbled_at=datetime.now(timezone.utc),
                source_zone=zone_name,
                lastfm_synced=synced,
            )
            session.add(scrobble)
            session.commit()

        return True

    def update_now_playing(
        self,
        artist: str,
        title: str,
        album: str | None = None,
        duration: int | None = None,
    ) -> None:
        """Send a 'now playing' notification to last.fm.

        Args:
            artist: Artist name.
            title: Track title.
            album: Album name.
            duration: Track duration in seconds.
        """
        try:
            self.network.update_now_playing(
                artist=artist,
                title=title,
                album=album or "",
                duration=duration,
            )
            log.debug("Now playing: %s - %s", artist, title)
        except Exception:
            log.exception("Error updating now playing")
