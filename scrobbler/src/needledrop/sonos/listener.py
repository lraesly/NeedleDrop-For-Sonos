"""Event-based Sonos track monitoring using UPnP subscriptions."""

import concurrent.futures
import logging
import threading
import time
from dataclasses import dataclass, field
from queue import Empty

import soco
from soco.events import event_listener

from needledrop.config import NeedleDropConfig
from needledrop.scrobbler.lastfm import LastFMScrobbler
from needledrop.sonos.discovery import SonosDiscovery

log = logging.getLogger(__name__)

# Duration string format: H:MM:SS has 3 parts
_HMS_PARTS = 3

# Sonos HDMI/TV audio stream URI prefix
_TV_AUDIO_URI_PREFIX = "x-sonos-htastream://"


def _is_sonos_internal(value: str) -> bool:
    """Return True if a metadata string looks like a Sonos internal identifier."""
    v = value.lower()
    return v.startswith(("x-", "zp", "rincon_")) or "://" in v


def parse_duration(duration_str: str) -> int:
    """Parse a duration string like '0:04:32' or '4:32' into seconds."""
    parts = duration_str.split(":")
    if len(parts) == _HMS_PARTS:
        return int(parts[0]) * 3600 + int(parts[1]) * 60 + int(parts[2])
    return int(parts[0]) * 60 + int(parts[1])


def _parse_stream_content(content: str) -> dict[str, str]:
    """Parse SiriusXM/radio stream_content into artist/title/album.

    Handles formats like:
        'TYPE=SNG|TITLE Some Title|ARTIST Some Artist|ALBUM Some Album'
        'Artist Name - Track Title'
    """
    result: dict[str, str] = {}

    if "|" in content:
        # Pipe-delimited key-value format (SiriusXM)
        for part in content.split("|"):
            part = part.strip()
            if part.startswith("ARTIST "):
                result["artist"] = part[7:].strip()
            elif part.startswith("TITLE "):
                result["title"] = part[6:].strip()
            elif part.startswith("ALBUM "):
                result["album"] = part[6:].strip()
    elif " - " in content:
        # Simple "Artist - Title" format
        parts = content.split(" - ", 1)
        result["artist"] = parts[0].strip()
        result["title"] = parts[1].strip()

    return result


@dataclass
class TrackPlaybackState:
    """Tracks playback state for a single speaker/coordinator."""

    artist: str
    title: str
    album: str | None
    album_artist: str | None
    duration_seconds: int
    transport_state: str  # PLAYING, PAUSED_PLAYBACK, STOPPED, TRANSITIONING
    zone_name: str
    album_art_url: str | None = None
    source_uri: str | None = None  # Sonos transport URI — matches favorite URIs
    started_playing_at: float | None = None  # time.monotonic()
    paused_at: float | None = None  # time.monotonic() — set when transitioning to PAUSED
    accumulated_play_seconds: float = 0.0
    scrobbled: bool = False

    @property
    def track_id(self) -> str:
        return f"{self.artist}-{self.title}"


@dataclass
class _DeviceContext:
    """Internal state for a subscribed device."""

    device: soco.SoCo
    subscription: object | None = None
    thread: threading.Thread | None = None
    scrobble_timer: threading.Timer | None = None
    track_state: TrackPlaybackState | None = None
    source_uri: str | None = None  # Sonos AVTransportURI — persists across track changes
    running: bool = False
    backoff: float = 1.0

    # Station-transition art capture.  When switching stations, the first
    # metadata event has the correct new station art but no track info yet.
    # Later events may carry stale art from the previous station alongside
    # the new track's title/artist.  We capture the first art URL after a
    # station change so it can be used when the track change fires.
    _pending_art_url: str | None = None
    _awaiting_station_art: bool = False
    # Track av_transport_uri separately for reliable station change detection.
    # enqueued_transport_uri often differs from av_transport_uri for the same
    # station, which causes false station-change triggers if we compare against
    # the combined source_uri.
    _last_av_uri: str | None = None


class SonosListener:
    """Manages UPnP event subscriptions and scrobble timing for Sonos devices."""

    def __init__(
        self,
        discovery: SonosDiscovery,
        scrobbler: LastFMScrobbler,
        config: NeedleDropConfig,
    ):
        self._discovery = discovery
        self._scrobbler = scrobbler
        self._config = config
        self._contexts: dict[str, _DeviceContext] = {}  # ip -> context
        self._lock = threading.Lock()
        self._running = False
        self._discovery_thread: threading.Thread | None = None
        self._track_change_callbacks: list = []
        self._art_cache: dict[str, str | None] = {}  # "artist-title" -> URL or None

    def on_track_change(self, callback) -> None:
        """Register a callback for track/transport state changes.

        Callback signature: callback(track_state: TrackPlaybackState)
        Called from listener threads — callers must handle thread safety.
        """
        self._track_change_callbacks.append(callback)

    # How long a PAUSED track is considered "now playing" before going stale.
    _PAUSE_STALE_SECONDS = 30 * 60  # 30 minutes

    def get_now_playing(self) -> list[TrackPlaybackState]:
        """Return current track state for all active zones.

        Only returns tracks that are actively playing or *recently* paused.
        Tracks paused for more than 30 minutes are considered stale (e.g. a
        speaker left in a paused state from hours/days ago).  Tracks that
        arrived already paused on server startup (no ``paused_at``) are also
        excluded since they were never seen playing by this server instance.
        """
        now = time.monotonic()
        result: list[TrackPlaybackState] = []
        with self._lock:
            for ctx in self._contexts.values():
                ts = ctx.track_state
                if ts is None:
                    continue
                if ts.transport_state == "PLAYING":
                    result.append(ts)
                elif ts.transport_state == "PAUSED_PLAYBACK":
                    # Exclude tracks that were never seen playing (stale on startup)
                    if ts.paused_at is None:
                        continue
                    # Exclude tracks paused too long ago
                    if (now - ts.paused_at) > self._PAUSE_STALE_SECONDS:
                        continue
                    result.append(ts)
        return result

    # -- Playback controls ------------------------------------------------

    def _find_device(self, zone: str | None = None) -> _DeviceContext | None:
        """Find a device context by zone name, or the first playing device."""
        with self._lock:
            if zone:
                for ctx in self._contexts.values():
                    if ctx.device.player_name == zone:
                        return ctx
                return None
            # No zone specified — prefer the currently playing device
            for ctx in self._contexts.values():
                if ctx.track_state and ctx.track_state.transport_state == "PLAYING":
                    return ctx
            # Fall back to any device with a track state
            for ctx in self._contexts.values():
                if ctx.track_state:
                    return ctx
            # Fall back to any device at all
            for ctx in self._contexts.values():
                return ctx
            return None

    def play(self, zone: str | None = None) -> bool:
        """Resume playback on a zone (or the active zone)."""
        ctx = self._find_device(zone)
        if ctx is None:
            return False
        try:
            ctx.device.play()
            return True
        except Exception:
            log.exception("Failed to play on %s", ctx.device.player_name)
            return False

    def pause(self, zone: str | None = None) -> bool:
        """Pause playback on a zone (or the active zone)."""
        ctx = self._find_device(zone)
        if ctx is None:
            return False
        try:
            ctx.device.pause()
            return True
        except Exception:
            log.exception("Failed to pause on %s", ctx.device.player_name)
            return False

    def next_track(self, zone: str | None = None) -> bool:
        """Skip to next track on a zone (or the active zone)."""
        ctx = self._find_device(zone)
        if ctx is None:
            return False
        try:
            ctx.device.next()
            return True
        except Exception:
            log.exception("Failed to skip on %s", ctx.device.player_name)
            return False

    def previous_track(self, zone: str | None = None) -> bool:
        """Go to previous track on a zone (or the active zone)."""
        ctx = self._find_device(zone)
        if ctx is None:
            return False
        try:
            ctx.device.previous()
            return True
        except Exception:
            log.exception("Failed to go back on %s", ctx.device.player_name)
            return False

    def get_volume(self, zone: str | None = None) -> int | None:
        """Get volume level (0-100) for a zone (or the active zone)."""
        ctx = self._find_device(zone)
        if ctx is None:
            return None
        try:
            return ctx.device.volume
        except Exception:
            log.exception("Failed to get volume on %s", ctx.device.player_name)
            return None

    def set_volume(self, level: int, zone: str | None = None) -> bool:
        """Set volume level (0-100) on a zone (or the active zone)."""
        ctx = self._find_device(zone)
        if ctx is None:
            return False
        try:
            ctx.device.volume = max(0, min(100, level))
            return True
        except Exception:
            log.exception("Failed to set volume on %s", ctx.device.player_name)
            return False

    # -- Favorites & Zones -----------------------------------------------

    def get_favorites(self) -> list[dict]:
        """Fetch Sonos Favorites (account-level, same on all speakers)."""
        ctx = self._find_device()
        if ctx is None:
            return []
        try:
            favorites = ctx.device.music_library.get_sonos_favorites()
            result = []
            for fav in favorites:
                # Skip non-playable items (shortcuts like "Discover Sonos Radio")
                if not fav.resources:
                    continue
                art = getattr(fav, "album_art_uri", None) or None
                if art and not art.startswith(("http://", "https://")):
                    art = f"http://{ctx.device.ip_address}:1400{art}"
                result.append({
                    "title": fav.title,
                    "uri": fav.resources[0].uri,
                    "meta": getattr(fav, "resource_meta_data", "") or "",
                    "album_art_uri": art,
                })
            return result
        except Exception:
            log.exception("Failed to fetch Sonos favorites")
            return []

    def play_favorite(self, uri: str, meta: str = "", zone: str | None = None) -> bool:
        """Play a Sonos Favorite by URI. Targets the zone's group coordinator."""
        ctx = self._find_device(zone)
        if ctx is None:
            return False
        try:
            coordinator = ctx.device.group.coordinator
            coordinator.play_uri(uri, meta=meta)
            return True
        except Exception:
            log.exception("Failed to play favorite on %s", ctx.device.player_name)
            return False

    def get_zones(self) -> list[dict]:
        """Return all monitored zones with group members and playback state."""
        with self._lock:
            zones = []
            for ctx in self._contexts.values():
                transport = "idle"
                if ctx.track_state:
                    ts = ctx.track_state.transport_state.lower()
                    transport = "paused" if ts == "paused_playback" else ts
                try:
                    members = sorted({
                        m.player_name
                        for m in ctx.device.group.members
                        if m.is_visible
                    })
                except Exception:
                    members = [ctx.device.player_name]
                zones.append({
                    "name": ctx.device.player_name,
                    "members": members,
                    "transport_state": transport,
                    "is_coordinator": True,
                })
            return sorted(zones, key=lambda z: z["name"])

    def get_all_speakers(self) -> list[dict]:
        """Return every visible speaker in the household with its group coordinator."""
        speakers = []
        for device in self._discovery._devices.values():
            if not device.is_visible:
                continue
            try:
                group = device.group
                coord_name = group.coordinator.player_name if group else device.player_name
                is_coord = (group.coordinator.ip_address == device.ip_address) if group else True
            except Exception:
                coord_name = device.player_name
                is_coord = True
            speakers.append({
                "name": device.player_name,
                "group_coordinator": coord_name,
                "is_coordinator": is_coord,
            })
        return sorted(speakers, key=lambda s: s["name"])

    def join_zone(self, speaker_name: str, coordinator_name: str) -> bool:
        """Join a speaker to another speaker's group."""
        speaker = self._find_speaker_by_name(speaker_name)
        coordinator = self._find_speaker_by_name(coordinator_name)
        if speaker is None or coordinator is None:
            return False
        try:
            speaker.join(coordinator)
            return True
        except Exception:
            log.exception("Failed to join %s to %s", speaker_name, coordinator_name)
            return False

    def unjoin_zone(self, speaker_name: str) -> bool:
        """Remove a speaker from its group."""
        speaker = self._find_speaker_by_name(speaker_name)
        if speaker is None:
            return False
        try:
            speaker.unjoin()
            return True
        except Exception:
            log.exception("Failed to unjoin %s", speaker_name)
            return False

    def _find_speaker_by_name(self, name: str) -> "soco.SoCo | None":
        """Find any speaker by name from all discovered devices."""
        for device in self._discovery._devices.values():
            if device.player_name == name:
                return device
        return None

    # -- Lifecycle -------------------------------------------------------

    def start(self) -> None:
        """Start listening: discover devices, subscribe, and begin event loops."""
        self._running = True
        log.info("Starting NeedleDrop listener")

        self._discovery.discover()
        coordinators = self._discovery.get_coordinators()

        for device in coordinators:
            self._subscribe_device(device)

        self._discovery_thread = threading.Thread(
            target=self._discovery_loop, daemon=True, name="discovery"
        )
        self._discovery_thread.start()
        log.info(
            "Listening to %d coordinator(s). Discovery interval: %ds",
            len(coordinators),
            self._config.sonos.discovery_interval,
        )

    def stop(self) -> None:
        """Unsubscribe all devices and stop the event listener."""
        log.info("Stopping NeedleDrop listener")
        self._running = False

        with self._lock:
            for ip in list(self._contexts.keys()):
                self._unsubscribe_device(ip)

        try:
            event_listener.stop()
        except Exception:
            log.debug("Event listener already stopped")

        if self._discovery_thread and self._discovery_thread.is_alive():
            self._discovery_thread.join(timeout=5)

    def _subscribe_device(self, device: soco.SoCo) -> None:
        """Subscribe to AVTransport events for a single device."""
        ip = device.ip_address
        zone = device.player_name

        with self._lock:
            if ip in self._contexts and self._contexts[ip].running:
                return

        try:
            sub = device.avTransport.subscribe(auto_renew=True)
            sub.auto_renew_fail = lambda exc: self._on_renew_fail(ip, exc)
        except Exception:
            log.exception("Failed to subscribe to %s (%s)", zone, ip)
            return

        ctx = _DeviceContext(device=device, subscription=sub, running=True)
        ctx.thread = threading.Thread(
            target=self._event_loop, args=(ip,), daemon=True, name=f"events-{zone}"
        )

        with self._lock:
            self._contexts[ip] = ctx

        ctx.thread.start()
        log.info("Subscribed to %s (%s)", zone, ip)

    def _unsubscribe_device(self, ip: str) -> None:
        """Unsubscribe and clean up state for a device."""
        ctx = self._contexts.pop(ip, None)
        if ctx is None:
            return

        ctx.running = False
        self._cancel_timer(ctx)

        if ctx.subscription:
            try:
                ctx.subscription.unsubscribe()
            except Exception:
                log.debug("Error unsubscribing %s", ip)

        if ctx.thread and ctx.thread.is_alive():
            ctx.thread.join(timeout=3)

    def _event_loop(self, ip: str) -> None:
        """Poll subscription event queue for a single device."""
        ctx = self._contexts.get(ip)
        zone = ctx.device.player_name if ctx else ip
        log.debug("Event loop started for %s (%s)", zone, ip)
        timeout_count = 0

        while self._running:
            ctx = self._contexts.get(ip)
            if ctx is None or not ctx.running:
                log.debug("Event loop exiting for %s: context gone or stopped", zone)
                break

            try:
                event = ctx.subscription.events.get(timeout=5)
                timeout_count = 0
                log.debug(
                    "Event received for %s: variables=%s",
                    zone,
                    list(event.variables.keys()) if hasattr(event, 'variables') else 'no variables',
                )
                self._handle_event(ip, event)
                ctx.backoff = 1.0  # reset backoff on success
            except Empty:
                timeout_count += 1
                if timeout_count % 12 == 0:  # log every ~60s
                    log.debug("Event loop heartbeat for %s: %d timeouts", zone, timeout_count)
                continue
            except Exception:
                log.exception("Error in event loop for %s", ip)
                ctx.backoff = min(ctx.backoff * 2, 60)
                time.sleep(ctx.backoff)

                if self._running and ctx.running:
                    self._try_resubscribe(ip)
                break

    def _handle_event(self, ip: str, event: object) -> None:
        """Process a single AVTransport event."""
        ctx = self._contexts.get(ip)
        if ctx is None:
            return

        variables = event.variables  # type: ignore[attr-defined]
        new_transport = variables.get("transport_state")
        meta = variables.get("current_track_meta_data")
        duration_str = variables.get("current_track_duration")

        # Capture the media source URI (matches Sonos favorite URIs).
        # Only present when the source changes, so persist on context.
        # Use av_transport_uri (the actual stream) for station change detection
        # because enqueued_transport_uri frequently differs from av_transport_uri
        # for the same station, which would cause false station-change triggers.
        av_uri = variables.get("av_transport_uri")
        enqueued_uri = variables.get("enqueued_transport_uri")
        transport_uri = av_uri or enqueued_uri
        if transport_uri:
            ctx.source_uri = transport_uri

        station_changed = bool(av_uri and av_uri != ctx._last_av_uri)
        if av_uri:
            ctx._last_av_uri = av_uri
        if station_changed:
            # New station — prepare to capture art from early transition events
            # before stale metadata from the previous station arrives.
            ctx._pending_art_url = None
            ctx._awaiting_station_art = True

        zone = ctx.device.player_name
        log.debug(
            "Handling event for %s: transport=%s, meta_type=%s, duration=%s",
            zone, new_transport, type(meta).__name__ if meta else None, duration_str,
        )

        # Detect TV/HDMI audio — soundbar switched away from music.
        # Scrobble any in-flight music track, clear stale metadata, and
        # broadcast a "TV audio" state so clients show the right thing.
        if transport_uri and transport_uri.startswith(_TV_AUDIO_URI_PREFIX):
            log.info("TV audio detected on %s (URI: %s)", zone, transport_uri)
            if ctx.track_state and not ctx.track_state.scrobbled:
                self._evaluate_scrobble(ctx)
            self._cancel_timer(ctx)
            tv_state = TrackPlaybackState(
                artist="",
                title="TV",
                album=None,
                album_artist=None,
                duration_seconds=0,
                transport_state=new_transport or "PLAYING",
                zone_name=zone,
                source_uri=transport_uri,
            )
            ctx.track_state = tv_state
            for cb in self._track_change_callbacks:
                try:
                    cb(tv_state)
                except Exception:
                    log.exception("Error in track change callback")
            return

        # Extract track metadata if present
        new_artist: str | None = None
        new_title: str | None = None
        new_album: str | None = None
        new_duration: int | None = None
        new_art_url: str | None = None

        if meta and not isinstance(meta, str):
            # Dump all attributes for debugging
            meta_attrs = {
                attr: getattr(meta, attr, None)
                for attr in dir(meta)
                if not attr.startswith("_") and not callable(getattr(meta, attr, None))
            }
            log.debug("Full meta attrs for %s: %s", zone, meta_attrs)

            new_artist = getattr(meta, "creator", None) or None
            new_title = getattr(meta, "title", None) or None
            new_album = getattr(meta, "album", None) or None

            # Album art: may be a relative path (/getaa?...) or full URL (http://...)
            art_uri = getattr(meta, "album_art_uri", None) or None
            if art_uri:
                if art_uri.startswith(("http://", "https://")):
                    new_art_url = art_uri
                else:
                    new_art_url = f"http://{ip}:1400{art_uri}"

            # During a station transition, capture the art from the first
            # metadata event.  Later events often carry stale art from the
            # previous station (e.g. SiriusXM album_art_uri lingers after
            # switching to SomaFM).  The first event's art is the most
            # reliable indicator of the new station's artwork.
            if new_art_url and ctx._awaiting_station_art and ctx._pending_art_url is None:
                ctx._pending_art_url = new_art_url
                ctx._awaiting_station_art = False
                log.debug("Captured station-transition art for %s: %s", zone, new_art_url)

            # For radio/streaming: parse stream_content metadata
            if not new_artist or not new_title:
                stream_content = getattr(meta, "stream_content", None) or ""
                log.debug("Stream content for %s: '%s'", zone, stream_content)

                if stream_content:
                    parsed = _parse_stream_content(stream_content)
                    if parsed.get("artist"):
                        new_artist = parsed["artist"]
                    if parsed.get("title"):
                        new_title = parsed["title"]
                    if parsed.get("album") and parsed["album"] != "undefined":
                        new_album = parsed["album"]

            # Filter out Sonos internal metadata strings (e.g. "ZP_STRING", "x-rincon-...")
            if new_title and _is_sonos_internal(new_title):
                log.debug("Filtered internal title on %s: %s", zone, new_title)
                new_title = None
            if new_artist and _is_sonos_internal(new_artist):
                log.debug("Filtered internal artist on %s: %s", zone, new_artist)
                new_artist = None

            log.debug("Parsed meta: artist=%s, title=%s, album=%s", new_artist, new_title, new_album)
        elif meta:
            log.debug("Meta present but is string: %.200s", str(meta))

        if duration_str and ":" in str(duration_str):
            try:
                new_duration = parse_duration(str(duration_str))
            except (ValueError, IndexError):
                pass

        current = ctx.track_state
        zone = ctx.device.player_name

        # Check for track change
        if new_artist and new_title:
            new_track_id = f"{new_artist}-{new_title}"
            old_track_id = current.track_id if current else None

            if new_track_id != old_track_id:
                # Prefer art captured during station transition over the
                # current event's art, which may be stale from the previous
                # station.  iTunes enrichment in _on_track_change will still
                # override if it finds per-track art.
                art_url = ctx._pending_art_url or new_art_url
                ctx._pending_art_url = None
                ctx._awaiting_station_art = False
                self._on_track_change(
                    ip, zone, new_artist, new_title, new_album,
                    new_duration or 0, new_transport or "PLAYING",
                    art_url, ctx.source_uri,
                )
                return

        # Check for transport state change (same track)
        if new_transport and current:
            if new_transport != current.transport_state:
                self._on_transport_change(ip, new_transport)

    def _lookup_album_art(self, artist: str, title: str) -> str | None:
        """Look up album art via the iTunes Search API.

        Fast, free, no auth required.  Returns a 600×600 image URL on hit.
        Uses an in-memory cache to avoid repeated API calls for the same track.
        Times out after 1.5 seconds so a slow response doesn't delay the
        track change broadcast — falls back to the Sonos-provided art.
        """
        import urllib.parse
        import urllib.request
        import json

        cache_key = f"{artist}-{title}"
        if cache_key in self._art_cache:
            return self._art_cache[cache_key]

        def _fetch():
            query = urllib.parse.urlencode({
                "term": f"{artist} {title}",
                "media": "music",
                "limit": "1",
            })
            url = f"https://itunes.apple.com/search?{query}"
            req = urllib.request.Request(url, headers={"User-Agent": "NeedleDrop/1.0"})
            with urllib.request.urlopen(req, timeout=1.5) as resp:
                data = json.loads(resp.read())
            results = data.get("results", [])
            if results:
                # Get the largest art: replace 100x100 default with 600x600
                art = results[0].get("artworkUrl100", "")
                return art.replace("100x100bb", "600x600bb") if art else None
            return None

        try:
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                cover = pool.submit(_fetch).result(timeout=1.5)
            self._art_cache[cache_key] = cover
            if cover:
                log.debug("iTunes art for %s - %s: %s", artist, title, cover)
            else:
                log.debug("No iTunes art found for %s - %s", artist, title)
            return cover
        except concurrent.futures.TimeoutError:
            log.debug("iTunes art lookup timed out for %s - %s", artist, title)
            # Don't cache timeouts — might succeed next time
            return None
        except Exception:
            log.debug("iTunes art lookup failed for %s - %s", artist, title, exc_info=True)
            self._art_cache[cache_key] = None
            return None

    def _on_track_change(
        self,
        ip: str,
        zone: str,
        artist: str,
        title: str,
        album: str | None,
        duration: int,
        transport_state: str,
        album_art_url: str | None = None,
        source_uri: str | None = None,
    ) -> None:
        """Handle a track identity change on a device."""
        ctx = self._contexts.get(ip)
        if ctx is None:
            return

        is_filtered = self._scrobbler.should_filter(artist, title, duration)

        # Evaluate the outgoing track for scrobbling before replacing state
        if not is_filtered and ctx.track_state and not ctx.track_state.scrobbled:
            self._evaluate_scrobble(ctx)

        self._cancel_timer(ctx)

        if is_filtered:
            log.info("Filtered track on %s: %s - %s (display only, no scrobble)", zone, artist, title)
        else:
            log.info("Now playing on %s: %s - %s", zone, artist, title)

        # Enrich album art from Last.fm — much better than station logos for radio.
        # For filtered tracks (DJ breaks etc.) this will typically miss, leaving
        # the Sonos-provided art (station logo) which is the desired behavior.
        enriched_art = self._lookup_album_art(artist, title)
        if enriched_art:
            album_art_url = enriched_art

        new_state = TrackPlaybackState(
            artist=artist,
            title=title,
            album=album,
            album_artist=None,
            duration_seconds=duration,
            transport_state=transport_state,
            zone_name=zone,
            album_art_url=album_art_url,
            source_uri=source_uri,
        )

        if transport_state == "PLAYING" and not is_filtered:
            new_state.started_playing_at = time.monotonic()

        ctx.track_state = new_state

        # Notify registered callbacks (e.g. API WebSocket broadcast).
        # Filtered tracks (DJ announcements) are broadcast so clients can
        # update the display, but won't be scrobbled.
        # Skip STOPPED tracks — on server startup, stale metadata arrives
        # from Sonos devices that aren't playing.  Active stop transitions
        # are handled by _on_transport_change which broadcasts correctly.
        if transport_state != "STOPPED":
            for cb in self._track_change_callbacks:
                try:
                    cb(new_state)
                except Exception:
                    log.exception("Error in track change callback")

        # Send now-playing to last.fm (skip filtered tracks)
        if transport_state == "PLAYING" and not is_filtered:
            self._scrobbler.update_now_playing(artist, title, album, duration)
            self._schedule_scrobble(ctx)

    def _on_transport_change(self, ip: str, new_state: str) -> None:
        """Handle play/pause/stop transitions for the current track."""
        ctx = self._contexts.get(ip)
        if ctx is None or ctx.track_state is None:
            return

        track = ctx.track_state
        old_state = track.transport_state
        track.transport_state = new_state

        if old_state == "PLAYING" and new_state != "PLAYING":
            # Accumulate play time
            if track.started_playing_at is not None:
                elapsed = time.monotonic() - track.started_playing_at
                track.accumulated_play_seconds += elapsed
                track.started_playing_at = None
            track.paused_at = time.monotonic()
            self._cancel_timer(ctx)
            log.debug(
                "Paused/stopped on %s: accumulated %.1fs",
                track.zone_name,
                track.accumulated_play_seconds,
            )
            # Notify callbacks of transport change
            for cb in self._track_change_callbacks:
                try:
                    cb(track)
                except Exception:
                    log.exception("Error in track change callback")

        elif new_state == "PLAYING" and old_state != "PLAYING":
            # Resuming playback
            track.started_playing_at = time.monotonic()
            track.paused_at = None
            log.debug("Resumed on %s", track.zone_name)
            # Notify callbacks of resume
            for cb in self._track_change_callbacks:
                try:
                    cb(track)
                except Exception:
                    log.exception("Error in track change callback")

            if not track.scrobbled and not self._scrobbler.should_filter(
                track.artist, track.title, track.duration_seconds
            ):
                self._schedule_scrobble(ctx)
                self._scrobbler.update_now_playing(
                    track.artist, track.title, track.album, track.duration_seconds
                )

    def _schedule_scrobble(self, ctx: _DeviceContext) -> None:
        """Compute time until scrobble threshold and start a timer."""
        track = ctx.track_state
        if track is None or track.scrobbled or track.transport_state != "PLAYING":
            return

        if track.duration_seconds > 0:
            # Known duration: scrobble at configured percentage of the track
            threshold = track.duration_seconds * self._config.scrobble.threshold_percent / 100
        else:
            # Radio/streaming with no duration: use fixed threshold
            threshold = self._config.scrobble.min_seconds
        remaining = threshold - track.accumulated_play_seconds

        if remaining <= 0:
            self._fire_scrobble(ctx)
            return

        self._cancel_timer(ctx)
        timer = threading.Timer(remaining, self._fire_scrobble, args=(ctx,))
        timer.daemon = True
        timer.start()
        ctx.scrobble_timer = timer
        log.debug(
            "Scrobble timer set for %s: %.1fs remaining (threshold %.1fs)",
            track.zone_name,
            remaining,
            threshold,
        )

    def _fire_scrobble(self, ctx: _DeviceContext) -> None:
        """Timer callback: verify track is still playing and scrobble."""
        track = ctx.track_state
        if track is None or track.scrobbled:
            return

        # Accumulate any in-flight play time
        if track.transport_state == "PLAYING" and track.started_playing_at is not None:
            elapsed = time.monotonic() - track.started_playing_at
            total = track.accumulated_play_seconds + elapsed
        else:
            total = track.accumulated_play_seconds

        if track.duration_seconds > 0:
            # Known duration: scrobble at configured percentage of the track
            threshold = track.duration_seconds * self._config.scrobble.threshold_percent / 100
        else:
            # Radio/streaming with no duration: use fixed threshold
            threshold = self._config.scrobble.min_seconds

        if total >= threshold:
            success = self._scrobbler.scrobble(
                artist=track.artist,
                title=track.title,
                album=track.album,
                album_artist=track.album_artist,
                duration=track.duration_seconds,
                zone_name=track.zone_name,
            )
            if success:
                track.scrobbled = True

    def _evaluate_scrobble(self, ctx: _DeviceContext) -> None:
        """Evaluate the current track for scrobbling (on track change/stop)."""
        self._fire_scrobble(ctx)

    def _cancel_timer(self, ctx: _DeviceContext) -> None:
        """Cancel any pending scrobble timer."""
        if ctx.scrobble_timer is not None:
            ctx.scrobble_timer.cancel()
            ctx.scrobble_timer = None

    def _on_renew_fail(self, ip: str, exception: Exception) -> None:
        """Handle subscription auto-renewal failure."""
        log.error("Subscription renewal failed for %s: %s", ip, exception)
        if self._running:
            self._try_resubscribe(ip)

    def _try_resubscribe(self, ip: str) -> None:
        """Attempt to resubscribe to a device after failure."""
        ctx = self._contexts.get(ip)
        if ctx is None:
            return

        device = ctx.device
        zone = device.player_name
        self._unsubscribe_device(ip)

        delay = min(ctx.backoff, 60)
        log.info("Resubscribing to %s in %.0fs", zone, delay)

        def _resubscribe():
            time.sleep(delay)
            if self._running:
                self._subscribe_device(device)

        thread = threading.Thread(target=_resubscribe, daemon=True, name=f"resub-{zone}")
        thread.start()

    def _discovery_loop(self) -> None:
        """Periodically re-discover Sonos devices and manage subscriptions."""
        interval = self._config.sonos.discovery_interval

        while self._running:
            time.sleep(interval)
            if not self._running:
                break

            try:
                self._discovery.discover()
                coordinators = self._discovery.get_coordinators()
                coordinator_ips = {d.ip_address for d in coordinators}

                # Subscribe to new coordinators
                for device in coordinators:
                    if device.ip_address not in self._contexts:
                        self._subscribe_device(device)

                # Unsubscribe from stale devices
                with self._lock:
                    stale = [
                        ip for ip in self._contexts
                        if ip not in coordinator_ips
                    ]
                for ip in stale:
                    log.info("Unsubscribing from stale device %s", ip)
                    self._unsubscribe_device(ip)

            except Exception:
                log.exception("Error in discovery loop")
