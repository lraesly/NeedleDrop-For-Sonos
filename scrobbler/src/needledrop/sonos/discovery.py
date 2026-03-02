"""Sonos device discovery and database persistence."""

import logging
from datetime import datetime, timezone

import soco

from sqlalchemy.orm import Session, sessionmaker

from needledrop.config import NeedleDropConfig
from needledrop.database.models import SonosDevice

log = logging.getLogger(__name__)


class SonosDiscovery:
    """Discovers Sonos speakers and persists them to the database."""

    def __init__(self, config: NeedleDropConfig, session_factory: sessionmaker[Session]):
        self._config = config
        self._session_factory = session_factory
        self._devices: dict[str, soco.SoCo] = {}  # ip -> SoCo

    @property
    def devices(self) -> dict[str, soco.SoCo]:
        """Current known devices keyed by IP address."""
        return dict(self._devices)

    def discover(self) -> dict[str, soco.SoCo]:
        """Run device discovery, update internal state and database.

        Returns:
            Dict of ip_address -> SoCo for all discovered devices.
        """
        try:
            found = soco.discover()
            if found is None:
                log.warning("No Sonos speakers found on the network")
                return self._devices
        except Exception:
            log.exception("Error during Sonos discovery")
            return self._devices

        new_devices: dict[str, soco.SoCo] = {s.ip_address: s for s in found}

        old_ips = set(self._devices.keys())
        new_ips = set(new_devices.keys())
        added = new_ips - old_ips
        removed = old_ips - new_ips

        if added or removed:
            for ip in added:
                name = new_devices[ip].player_name
                log.info("New speaker found: %s (%s)", name, ip)
            for ip in removed:
                name = self._devices[ip].player_name
                log.info("Speaker removed: %s (%s)", name, ip)
            log.info("Speaker count: %d", len(new_devices))

        self._devices = new_devices
        self._update_db(new_devices)
        return self._devices

    def get_coordinators(self) -> list[soco.SoCo]:
        """Return group coordinators for monitored zones.

        Only subscribes to coordinators to avoid duplicate scrobbles
        from grouped zones.
        """
        monitored_zones = self._config.sonos.monitored_zones
        seen_coordinators: set[str] = set()
        coordinators: list[soco.SoCo] = []

        for device in self._devices.values():
            try:
                coordinator = device.group.coordinator
                coord_ip = coordinator.ip_address

                if coord_ip in seen_coordinators:
                    continue
                seen_coordinators.add(coord_ip)

                if monitored_zones:
                    zone_name = coordinator.player_name
                    if zone_name not in monitored_zones:
                        log.debug("Skipping unmonitored zone: %s", zone_name)
                        continue

                coordinators.append(coordinator)
            except Exception:
                log.exception(
                    "Error getting coordinator for %s", device.player_name
                )

        return coordinators

    def _update_db(self, devices: dict[str, soco.SoCo]) -> None:
        """Upsert discovered devices into the database."""
        now = datetime.now(timezone.utc)
        monitored_zones = self._config.sonos.monitored_zones

        with self._session_factory() as session:
            for ip, device in devices.items():
                name = device.player_name
                existing = (
                    session.query(SonosDevice)
                    .filter_by(ip_address=ip)
                    .first()
                )
                if existing:
                    existing.name = name
                    existing.last_seen = now
                else:
                    monitored = (
                        name in monitored_zones if monitored_zones else True
                    )
                    session.add(
                        SonosDevice(
                            name=name,
                            ip_address=ip,
                            monitored=monitored,
                            last_seen=now,
                        )
                    )
            session.commit()
