"""Slim FastAPI server — status, scrobble history, filter config, Last.fm config.

No playback controls, no favorites, no zones, no Spotify, no WebSocket.
The Swift app handles all Sonos control directly via UPnP.
"""

import logging
import re
import time
from datetime import datetime, timezone

import uvicorn
from fastapi import Depends, FastAPI, Query, status
from fastapi.exceptions import HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel
from sqlalchemy.orm import Session, sessionmaker

from needledrop import __version__
from needledrop.config import NeedleDropConfig, ScrobbleFilters, save_config
from needledrop.database.stats import get_recent_scrobbles
from needledrop.scrobbler.lastfm import CompiledFilters
from needledrop.sonos.listener import SonosListener

log = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Pydantic models
# ---------------------------------------------------------------------------

class StatusResponse(BaseModel):
    status: str
    version: str


class ControlResponse(BaseModel):
    success: bool
    message: str


class ScrobbleResponse(BaseModel):
    id: int
    artist: str
    track: str
    album: str | None
    scrobbled_at: str
    source_zone: str | None
    lastfm_synced: bool


class FilterRule(BaseModel):
    field: str   # "artist" or "title"
    mode: str    # "exact", "starts_with", "contains", "regex"
    value: str


class ScrobbleFiltersResponse(BaseModel):
    min_duration: int
    rules: list[FilterRule]


class ScrobbleFiltersRequest(BaseModel):
    min_duration: int
    rules: list[FilterRule]


class LastFMCredentialsRequest(BaseModel):
    api_key: str
    api_secret: str
    username: str
    password_hash: str


# ---------------------------------------------------------------------------
# Filter rule ↔ regex conversion
# ---------------------------------------------------------------------------

def _regex_to_rule(field: str, pattern: str) -> FilterRule:
    """Reverse-engineer a regex pattern into a friendly FilterRule."""
    if pattern.startswith("^") and pattern.endswith("$"):
        inner = pattern[1:-1]
        if not re.search(r"[.+*?\\()\[\]{}|]", inner):
            return FilterRule(field=field, mode="exact", value=inner)

    if pattern.startswith("^") and pattern.endswith(".*"):
        inner = pattern[1:-2]
        if not re.search(r"[.+*?\\()\[\]{}|]", inner):
            return FilterRule(field=field, mode="starts_with", value=inner)

    if pattern.startswith(".*") and pattern.endswith(".*"):
        inner = pattern[2:-2]
        if not re.search(r"[.+*?\\()\[\]{}|]", inner):
            return FilterRule(field=field, mode="contains", value=inner)

    return FilterRule(field=field, mode="regex", value=pattern)


def _rule_to_regex(rule: FilterRule) -> str:
    """Convert a FilterRule to a regex pattern string."""
    v = rule.value
    if rule.mode == "exact":
        return f"^{re.escape(v)}$"
    elif rule.mode == "starts_with":
        return f"^{re.escape(v)}.*"
    elif rule.mode == "contains":
        return f".*{re.escape(v)}.*"
    else:  # regex
        return v


# ---------------------------------------------------------------------------
# App factory
# ---------------------------------------------------------------------------

def create_app(
    listener: SonosListener,
    config: NeedleDropConfig,
    session_factory: sessionmaker[Session],
) -> FastAPI:
    """Build the slim FastAPI application."""

    app = FastAPI(title="NeedleDrop Scrobbler", version=__version__)

    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_methods=["*"],
        allow_headers=["*"],
    )

    security = HTTPBearer()

    def verify_token(
        credentials: HTTPAuthorizationCredentials = Depends(security),
    ):
        if credentials.credentials != config.server.api_token:
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED)
        return credentials

    # -- Status --

    @app.get("/api/status", response_model=StatusResponse)
    async def get_status(_=Depends(verify_token)):
        return StatusResponse(status="ok", version=__version__)

    # -- Recent scrobbles --

    @app.get("/api/scrobbles/recent", response_model=list[ScrobbleResponse])
    async def get_recent(
        _=Depends(verify_token),
        limit: int = Query(20, ge=1, le=100),
    ):
        with session_factory() as session:
            scrobbles = get_recent_scrobbles(session, limit=limit)
            return [
                ScrobbleResponse(
                    id=s.id,
                    artist=s.artist,
                    track=s.track,
                    album=s.album,
                    scrobbled_at=s.scrobbled_at.isoformat() if s.scrobbled_at else "",
                    source_zone=s.source_zone,
                    lastfm_synced=s.lastfm_synced,
                )
                for s in scrobbles
            ]

    # -- Filter config --

    @app.get("/api/config/filters", response_model=ScrobbleFiltersResponse)
    async def get_filters(_=Depends(verify_token)):
        f = config.scrobble.filters
        rules: list[FilterRule] = []
        for pattern in f.artist_exclude:
            rules.append(_regex_to_rule("artist", pattern))
        for pattern in f.title_exclude:
            rules.append(_regex_to_rule("title", pattern))
        return ScrobbleFiltersResponse(min_duration=f.min_duration, rules=rules)

    @app.put("/api/config/filters", response_model=ControlResponse)
    async def set_filters(body: ScrobbleFiltersRequest, _=Depends(verify_token)):
        artist_patterns: list[str] = []
        title_patterns: list[str] = []
        for rule in body.rules:
            regex = _rule_to_regex(rule)
            try:
                re.compile(regex)
            except re.error as e:
                raise HTTPException(
                    status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                    detail=f"Invalid regex for {rule.field} rule '{rule.value}': {e}",
                )
            if rule.field == "artist":
                artist_patterns.append(regex)
            else:
                title_patterns.append(regex)

        config.scrobble.filters.min_duration = body.min_duration
        config.scrobble.filters.artist_exclude = artist_patterns
        config.scrobble.filters.title_exclude = title_patterns
        config.scrobble.filters.__post_init__()

        listener._scrobbler._filters = CompiledFilters(config.scrobble.filters)
        save_config(config)

        log.info(
            "Scrobble filters updated: %d artist rules, %d title rules, min_duration=%d",
            len(artist_patterns), len(title_patterns), body.min_duration,
        )
        return ControlResponse(success=True, message="Filters updated")

    # -- Last.fm config --

    @app.put("/api/config/lastfm", response_model=ControlResponse)
    async def set_lastfm_credentials(
        body: LastFMCredentialsRequest,
        _=Depends(verify_token),
    ):
        """Update Last.fm credentials. Requires service restart to take effect."""
        config.lastfm.api_key = body.api_key.strip()
        config.lastfm.api_secret = body.api_secret.strip()
        config.lastfm.username = body.username.strip()
        config.lastfm.password_hash = body.password_hash.strip()
        save_config(config)
        log.info("Last.fm credentials updated — restart required")
        return ControlResponse(
            success=True,
            message="Last.fm credentials saved. Restart scrobbler to apply.",
        )

    return app


# ---------------------------------------------------------------------------
# Server lifecycle
# ---------------------------------------------------------------------------

_uvicorn_server: uvicorn.Server | None = None


def start_api_server(
    listener: SonosListener,
    config: NeedleDropConfig,
    session_factory: sessionmaker[Session],
) -> None:
    """Start the FastAPI server (blocking — run in a daemon thread)."""
    global _uvicorn_server

    app = create_app(listener, config, session_factory)
    uvi_config = uvicorn.Config(
        app,
        host=config.server.host,
        port=config.server.port,
        log_level="warning",
        access_log=False,
    )
    _uvicorn_server = uvicorn.Server(uvi_config)
    _uvicorn_server.run()


def stop_api_server() -> None:
    """Signal the uvicorn server to shut down gracefully."""
    if _uvicorn_server is not None:
        _uvicorn_server.should_exit = True
