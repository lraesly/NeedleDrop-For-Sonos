"""Database query helpers for scrobble history and deduplication."""

from datetime import datetime, timedelta, timezone

from sqlalchemy import select
from sqlalchemy.orm import Session

from needledrop.database.models import Scrobble


def is_duplicate_scrobble(
    session: Session,
    artist: str,
    track: str,
    window_minutes: int = 30,
) -> bool:
    """Check if the same artist+track was scrobbled within the dedup window.

    Args:
        session: Active database session.
        artist: Artist name.
        track: Track title.
        window_minutes: Deduplication window in minutes.

    Returns:
        True if a matching scrobble exists within the window.
    """
    cutoff = datetime.now(timezone.utc) - timedelta(minutes=window_minutes)
    stmt = (
        select(Scrobble.id)
        .where(
            Scrobble.artist == artist,
            Scrobble.track == track,
            Scrobble.scrobbled_at >= cutoff,
        )
        .limit(1)
    )
    return session.execute(stmt).first() is not None


def get_recent_scrobbles(session: Session, limit: int = 20) -> list[Scrobble]:
    """Fetch the most recent scrobbles.

    Args:
        session: Active database session.
        limit: Maximum number of results.

    Returns:
        List of Scrobble objects ordered by most recent first.
    """
    stmt = (
        select(Scrobble)
        .order_by(Scrobble.scrobbled_at.desc())
        .limit(limit)
    )
    return list(session.scalars(stmt).all())
