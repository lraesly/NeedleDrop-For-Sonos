"""TOML configuration loading and saving for the slim scrobbler."""

import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

import tomli_w

if sys.version_info >= (3, 11):
    import tomllib
else:
    import tomli as tomllib


CONFIG_DIR = Path.home() / ".config" / "needledrop"
CONFIG_FILE = CONFIG_DIR / "config.toml"
DEFAULT_DB_PATH = CONFIG_DIR / "needledrop.db"


@dataclass
class ServerConfig:
    name: str = "Home"
    host: str = "0.0.0.0"
    port: int = 8484
    api_token: str = ""


@dataclass
class LastFMConfig:
    api_key: str = ""
    api_secret: str = ""
    username: str = ""
    password_hash: str = ""


@dataclass
class SonosConfig:
    auto_discover: bool = True
    discovery_interval: int = 300
    monitored_zones: list[str] = field(default_factory=list)


@dataclass
class ScrobbleFilters:
    min_duration: int = 90
    artist_exclude: list[str] = field(default_factory=lambda: ["^Unknown Artist$", "^$"])
    title_exclude: list[str] = field(default_factory=lambda: ["^#.*", "^@.*"])

    def __post_init__(self):
        self._artist_patterns: list[re.Pattern] = [
            re.compile(p) for p in self.artist_exclude
        ]
        self._title_patterns: list[re.Pattern] = [
            re.compile(p) for p in self.title_exclude
        ]

    @property
    def artist_patterns(self) -> list[re.Pattern]:
        return self._artist_patterns

    @property
    def title_patterns(self) -> list[re.Pattern]:
        return self._title_patterns


@dataclass
class ScrobbleConfig:
    threshold_percent: float = 50.0
    min_seconds: int = 30
    filters: ScrobbleFilters = field(default_factory=ScrobbleFilters)


@dataclass
class DatabaseConfig:
    path: str = str(DEFAULT_DB_PATH)

    @property
    def resolved_path(self) -> Path:
        return Path(self.path).expanduser()


@dataclass
class NeedleDropConfig:
    """Slim scrobbler config — no Spotify section."""
    server: ServerConfig = field(default_factory=ServerConfig)
    lastfm: LastFMConfig = field(default_factory=LastFMConfig)
    sonos: SonosConfig = field(default_factory=SonosConfig)
    scrobble: ScrobbleConfig = field(default_factory=ScrobbleConfig)
    database: DatabaseConfig = field(default_factory=DatabaseConfig)


def load_config(path: Path | None = None) -> NeedleDropConfig:
    """Load configuration from TOML file."""
    config_path = path or CONFIG_FILE

    if not config_path.exists():
        raise FileNotFoundError(
            f"Config file not found: {config_path}\n"
            "Run 'needledrop setup' to create one."
        )

    with config_path.open("rb") as f:
        data = tomllib.load(f)

    server_data = data.get("server", {})
    lastfm_data = data.get("lastfm", {})
    sonos_data = data.get("sonos", {})
    scrobble_data = data.get("scrobble", {})
    db_data = data.get("database", {})

    # Validate required last.fm fields
    missing = [
        k for k in ("api_key", "api_secret", "username", "password_hash")
        if not lastfm_data.get(k)
    ]
    if missing:
        raise ValueError(
            f"Missing required last.fm config fields: {', '.join(missing)}\n"
            "Run 'needledrop setup' to configure."
        )

    # Build filters
    filters_data = scrobble_data.pop("filters", {})
    filters = ScrobbleFilters(**filters_data) if filters_data else ScrobbleFilters()

    return NeedleDropConfig(
        server=ServerConfig(**server_data),
        lastfm=LastFMConfig(**lastfm_data),
        sonos=SonosConfig(**sonos_data),
        scrobble=ScrobbleConfig(filters=filters, **scrobble_data),
        database=DatabaseConfig(**db_data),
    )


def save_config(config: NeedleDropConfig, path: Path | None = None) -> None:
    """Write configuration to TOML file."""
    config_path = path or CONFIG_FILE
    config_path.parent.mkdir(parents=True, exist_ok=True)

    data = {
        "server": {
            "name": config.server.name,
            "host": config.server.host,
            "port": config.server.port,
            "api_token": config.server.api_token,
        },
        "lastfm": {
            "api_key": config.lastfm.api_key,
            "api_secret": config.lastfm.api_secret,
            "username": config.lastfm.username,
            "password_hash": config.lastfm.password_hash,
        },
        "sonos": {
            "auto_discover": config.sonos.auto_discover,
            "discovery_interval": config.sonos.discovery_interval,
        },
        "scrobble": {
            "threshold_percent": config.scrobble.threshold_percent,
            "min_seconds": config.scrobble.min_seconds,
            "filters": {
                "min_duration": config.scrobble.filters.min_duration,
                "artist_exclude": config.scrobble.filters.artist_exclude,
                "title_exclude": config.scrobble.filters.title_exclude,
            },
        },
        "database": {"path": config.database.path},
    }

    if config.sonos.monitored_zones:
        data["sonos"]["monitored_zones"] = config.sonos.monitored_zones

    with config_path.open("wb") as f:
        tomli_w.dump(data, f)
