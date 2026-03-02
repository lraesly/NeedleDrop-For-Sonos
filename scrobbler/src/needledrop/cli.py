"""NeedleDrop Scrobbler CLI — setup, run, info, recent, status, token."""

import atexit
import logging
import os
import secrets
import signal
import sys
import threading
from datetime import datetime, timezone
from pathlib import Path

import click
import pylast
from rich.console import Console
from rich.table import Table

from needledrop import __version__
from needledrop.config import (
    CONFIG_DIR,
    CONFIG_FILE,
    LastFMConfig,
    NeedleDropConfig,
    SonosConfig,
    ScrobbleConfig,
    ScrobbleFilters,
    ServerConfig,
    DatabaseConfig,
    load_config,
    save_config,
)
from needledrop.database import init_db, get_session_factory
from needledrop.database.stats import get_recent_scrobbles

console = Console()

PID_FILE = CONFIG_DIR / "needledrop.pid"
ERROR_FILE = CONFIG_DIR / "last_error"
LOG_DIR = CONFIG_DIR / "logs"


@click.group()
@click.version_option(version=__version__)
def cli():
    """NeedleDrop Scrobbler — Sonos to Last.fm (slim v2)."""


@cli.command()
def setup():
    """Interactive setup: configure Last.fm, discover Sonos, create config."""
    console.print("\n[bold]NeedleDrop Scrobbler Setup[/bold]\n")

    server_name = click.prompt("Server display name", default="Home")

    console.print("\n[bold]Last.fm Configuration[/bold]")
    console.print("Get API credentials at: https://www.last.fm/api/account/create\n")

    api_key = click.prompt("API Key")
    api_secret = click.prompt("API Secret", hide_input=True)
    username = click.prompt("Username")
    password = click.prompt("Password", hide_input=True)
    password_hash = pylast.md5(password)

    console.print("\nTesting Last.fm connection...")
    try:
        network = pylast.LastFMNetwork(
            api_key=api_key,
            api_secret=api_secret,
            username=username,
            password_hash=password_hash,
        )
        user = network.get_authenticated_user()
        console.print(
            f"[green]Connected![/green] Logged in as [bold]{user.get_name()}[/bold] "
            f"({user.get_playcount()} scrobbles)"
        )
    except Exception as e:
        console.print(f"[red]Connection failed:[/red] {e}")
        if not click.confirm("Save config anyway?", default=False):
            raise SystemExit(1)

    console.print("\n[bold]Sonos Discovery[/bold]")
    console.print("Searching for speakers...")

    monitored_zones: list[str] = []
    try:
        import soco
        found = soco.discover()
        if found:
            speakers = sorted(found, key=lambda s: s.player_name)
            table = Table(title="Discovered Speakers")
            table.add_column("#", style="dim")
            table.add_column("Name", style="cyan")
            table.add_column("IP", style="green")
            for i, s in enumerate(speakers, 1):
                table.add_row(str(i), s.player_name, s.ip_address)
            console.print(table)
            console.print("\nAll zones will be monitored by default.")
            if click.confirm("Restrict to specific zones?", default=False):
                zone_input = click.prompt(
                    "Zone names (comma-separated)",
                    default=", ".join(s.player_name for s in speakers),
                )
                monitored_zones = [z.strip() for z in zone_input.split(",") if z.strip()]
        else:
            console.print("[yellow]No speakers found.[/yellow] You can configure later.")
    except Exception as e:
        console.print(f"[yellow]Discovery failed:[/yellow] {e}")

    api_token = secrets.token_urlsafe(32)

    config = NeedleDropConfig(
        server=ServerConfig(name=server_name, api_token=api_token),
        lastfm=LastFMConfig(
            api_key=api_key,
            api_secret=api_secret,
            username=username,
            password_hash=password_hash,
        ),
        sonos=SonosConfig(monitored_zones=monitored_zones),
        scrobble=ScrobbleConfig(filters=ScrobbleFilters()),
        database=DatabaseConfig(),
    )

    save_config(config)
    console.print(f"\n[green]Config saved to {CONFIG_FILE}[/green]")

    db_path = config.database.resolved_path
    db_path.parent.mkdir(parents=True, exist_ok=True)
    init_db(str(db_path))
    console.print(f"[green]Database created at {db_path}[/green]")

    console.print(f"\n[green]API token:[/green] {api_token}")
    console.print("[dim]Enter this in NeedleDrop to connect.[/dim]")
    console.print("\n[bold green]Setup complete![/bold green] Run [cyan]needledrop run[/cyan] to start.\n")


def _write_error(message: str) -> None:
    ERROR_FILE.parent.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    ERROR_FILE.write_text(f"{timestamp}\n{message}\n")


def _clear_error() -> None:
    ERROR_FILE.unlink(missing_ok=True)


def _is_process_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def _acquire_pid_file() -> None:
    if PID_FILE.exists():
        try:
            old_pid = int(PID_FILE.read_text().strip())
        except ValueError:
            old_pid = None

        if old_pid and _is_process_alive(old_pid):
            msg = f"NeedleDrop is already running (PID {old_pid})."
            console.print(f"[red]{msg}[/red]")
            _write_error(msg)
            raise SystemExit(1)

    PID_FILE.parent.mkdir(parents=True, exist_ok=True)
    PID_FILE.write_text(str(os.getpid()))
    atexit.register(lambda: PID_FILE.unlink(missing_ok=True))


@cli.command()
@click.option("--log-level", default="INFO", type=click.Choice(["DEBUG", "INFO", "WARNING", "ERROR"]))
def run(log_level: str):
    """Start the scrobbler service."""
    logging.basicConfig(
        level=getattr(logging, log_level),
        format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
        datefmt="%H:%M:%S",
        force=True,
    )
    log = logging.getLogger("needledrop.cli")

    logging.getLogger("soco").setLevel(logging.WARNING)
    logging.getLogger("pylast").setLevel(logging.WARNING)

    _acquire_pid_file()

    try:
        config = load_config()
    except (FileNotFoundError, ValueError) as e:
        msg = f"Configuration error: {e}"
        log.error(msg)
        _write_error(msg)
        raise SystemExit(1)

    try:
        db_path = config.database.resolved_path
        db_path.parent.mkdir(parents=True, exist_ok=True)
        engine = init_db(str(db_path))
        session_factory = get_session_factory(engine)
    except Exception as e:
        msg = f"Database error: {e}"
        log.error(msg)
        _write_error(msg)
        raise SystemExit(1)

    from needledrop.scrobbler.lastfm import LastFMScrobbler
    from needledrop.sonos.discovery import SonosDiscovery
    from needledrop.sonos.listener import SonosListener

    try:
        scrobbler = LastFMScrobbler(config, session_factory)
        discovery = SonosDiscovery(config, session_factory)
        listener = SonosListener(discovery, scrobbler, config)
    except Exception as e:
        msg = f"Startup error: {e}"
        log.error(msg)
        _write_error(msg)
        raise SystemExit(1)

    shutdown_event = threading.Event()
    bonjour_advertiser = None

    def _shutdown(signum, _frame):
        sig_name = signal.Signals(signum).name
        console.print(f"\n[yellow]Received {sig_name}, shutting down...[/yellow]")
        if bonjour_advertiser:
            bonjour_advertiser.stop()
        from needledrop.server import stop_api_server
        stop_api_server()
        listener.stop()
        shutdown_event.set()

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    _clear_error()
    console.print(f"[bold]NeedleDrop Scrobbler[/bold] v{__version__} — {config.server.name}")
    listener.start()

    if config.server.api_token:
        from needledrop.server import start_api_server

        server_thread = threading.Thread(
            target=start_api_server,
            args=(listener, config, session_factory),
            daemon=True,
            name="api-server",
        )
        server_thread.start()
        console.print(
            f"[bold]API server[/bold] listening on "
            f"http://{config.server.host}:{config.server.port}"
        )

        from needledrop.bonjour import BonjourAdvertiser
        bonjour_advertiser = BonjourAdvertiser(config.server, __version__)
        bonjour_advertiser.start()
        console.print(
            f"[bold]Bonjour[/bold] advertising as "
            f"[cyan]{config.server.name}[/cyan]"
        )
    else:
        console.print("[yellow]No API token configured — API server disabled.[/yellow]")

    shutdown_event.wait()


@cli.command()
def info():
    """Show Last.fm account info."""
    try:
        config = load_config()
    except (FileNotFoundError, ValueError) as e:
        console.print(f"[red]{e}[/red]")
        raise SystemExit(1)

    with console.status("Connecting to Last.fm..."):
        try:
            network = pylast.LastFMNetwork(
                api_key=config.lastfm.api_key,
                api_secret=config.lastfm.api_secret,
                username=config.lastfm.username,
                password_hash=config.lastfm.password_hash,
            )
            user = network.get_authenticated_user()
            playcount = user.get_playcount()
        except Exception as e:
            console.print(f"[red]Connection failed:[/red] {e}")
            raise SystemExit(1)

    table = Table(title="Last.fm Account")
    table.add_column("Property", style="cyan")
    table.add_column("Value", style="green")
    table.add_row("Username", user.get_name())
    table.add_row("Total Scrobbles", f"{playcount:,}")
    console.print(table)


@cli.command()
@click.option("--limit", "-n", default=20, help="Number of recent scrobbles.")
def recent(limit: int):
    """Show recently scrobbled tracks."""
    try:
        config = load_config()
    except (FileNotFoundError, ValueError) as e:
        console.print(f"[red]{e}[/red]")
        raise SystemExit(1)

    db_path = config.database.resolved_path
    if not db_path.exists():
        console.print("[yellow]No database found. Run 'needledrop run' first.[/yellow]")
        raise SystemExit(1)

    engine = init_db(str(db_path))
    session_factory = get_session_factory(engine)

    with session_factory() as session:
        scrobbles = get_recent_scrobbles(session, limit=limit)

    if not scrobbles:
        console.print("[yellow]No scrobbles recorded yet.[/yellow]")
        return

    table = Table(title=f"Last {len(scrobbles)} Scrobbles")
    table.add_column("#", style="dim")
    table.add_column("Artist", style="cyan")
    table.add_column("Track", style="green")
    table.add_column("Album", style="blue")
    table.add_column("Zone", style="magenta")
    table.add_column("Time", style="dim")
    table.add_column("Synced", style="dim")

    for i, s in enumerate(scrobbles, 1):
        table.add_row(
            str(i),
            s.artist,
            s.track,
            s.album or "",
            s.source_zone or "",
            s.scrobbled_at.strftime("%Y-%m-%d %H:%M") if s.scrobbled_at else "",
            "[green]yes[/green]" if s.lastfm_synced else "[red]no[/red]",
        )

    console.print(table)


@cli.command()
def status():
    """Show whether NeedleDrop is running."""
    if PID_FILE.exists():
        try:
            pid = int(PID_FILE.read_text().strip())
        except ValueError:
            pid = None

        if pid and _is_process_alive(pid):
            console.print(f"[green]NeedleDrop is running[/green] (PID {pid})")
        else:
            console.print("[yellow]NeedleDrop is not running[/yellow] (stale PID file)")
    else:
        console.print("[yellow]NeedleDrop is not running[/yellow]")

    if ERROR_FILE.exists():
        error_text = ERROR_FILE.read_text().strip()
        console.print(f"\n[red]Last error:[/red]\n{error_text}")
    else:
        console.print("\n[dim]No recent errors.[/dim]")


@cli.command()
@click.option("--regenerate", is_flag=True, help="Generate a new API token.")
def token(regenerate: bool):
    """Show or regenerate the API token."""
    try:
        config = load_config()
    except (FileNotFoundError, ValueError) as e:
        console.print(f"[red]{e}[/red]")
        raise SystemExit(1)

    if regenerate or not config.server.api_token:
        config.server.api_token = secrets.token_urlsafe(32)
        save_config(config)
        console.print(f"[green]New API token:[/green] {config.server.api_token}")
        console.print("[dim]Restart NeedleDrop for the new token to take effect.[/dim]")
    else:
        console.print(f"[green]API token:[/green] {config.server.api_token}")
    console.print(f"[dim]Server: http://{config.server.host}:{config.server.port}[/dim]")
