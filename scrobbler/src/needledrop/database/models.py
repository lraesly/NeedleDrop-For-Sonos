"""SQLAlchemy ORM models."""

from datetime import datetime, timezone

from sqlalchemy import Boolean, DateTime, Index, Integer, String
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


class Base(DeclarativeBase):
    pass


class Scrobble(Base):
    __tablename__ = "scrobbles"

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    artist: Mapped[str] = mapped_column(String, nullable=False)
    track: Mapped[str] = mapped_column(String, nullable=False)
    album: Mapped[str | None] = mapped_column(String, nullable=True)
    album_artist: Mapped[str | None] = mapped_column(String, nullable=True)
    duration_seconds: Mapped[int | None] = mapped_column(Integer, nullable=True)
    scrobbled_at: Mapped[datetime] = mapped_column(
        DateTime,
        nullable=False,
        default=lambda: datetime.now(timezone.utc),
    )
    source_zone: Mapped[str | None] = mapped_column(String, nullable=True)
    lastfm_synced: Mapped[bool] = mapped_column(Boolean, default=False)

    __table_args__ = (
        Index("ix_scrobble_dedup", "artist", "track", "scrobbled_at"),
        Index("ix_scrobble_recent", "scrobbled_at"),
    )

    def __repr__(self) -> str:
        return f"<Scrobble {self.artist} - {self.track} @ {self.scrobbled_at}>"


class SonosDevice(Base):
    __tablename__ = "sonos_devices"

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    name: Mapped[str] = mapped_column(String, nullable=False)
    ip_address: Mapped[str] = mapped_column(String, nullable=False, index=True)
    monitored: Mapped[bool] = mapped_column(Boolean, default=True)
    last_seen: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)

    def __repr__(self) -> str:
        return f"<SonosDevice {self.name} ({self.ip_address})>"


class ServerInfo(Base):
    __tablename__ = "server_info"

    key: Mapped[str] = mapped_column(String, primary_key=True)
    value: Mapped[str | None] = mapped_column(String, nullable=True)
