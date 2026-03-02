"""Bonjour/mDNS service advertisement for NeedleDrop."""

from __future__ import annotations

import logging
import socket

from zeroconf import ServiceInfo, Zeroconf

from needledrop.config import ServerConfig

log = logging.getLogger(__name__)

SERVICE_TYPE = "_needledrop._tcp.local."


class BonjourAdvertiser:
    """Advertises a NeedleDrop server on the local network via mDNS/Bonjour.

    The TXT record carries enough information for clients to connect
    without manual configuration: server name, version, and API token.
    """

    def __init__(self, config: ServerConfig, version: str) -> None:
        self._config = config
        self._version = version
        self._zeroconf: Zeroconf | None = None
        self._info: ServiceInfo | None = None

    def start(self) -> None:
        """Register the mDNS service."""
        # Determine the IP address to advertise.
        # If the server is bound to 0.0.0.0, we need to find a real IP.
        host = self._config.host
        if host in ("0.0.0.0", "::"):
            host = self._get_local_ip()

        try:
            addresses = [socket.inet_aton(host)]
        except OSError:
            # Hostname rather than IP — resolve it
            try:
                resolved = socket.gethostbyname(host)
                addresses = [socket.inet_aton(resolved)]
            except OSError:
                log.warning("Could not resolve host %s for Bonjour — skipping", host)
                return

        service_name = f"{self._config.name}.{SERVICE_TYPE}"

        # Use the machine's real hostname so the SRV record resolves properly.
        # Without this, zeroconf defaults to the service name as the hostname
        # which can break NWConnection-based resolution on Apple clients.
        hostname = socket.gethostname()
        if not hostname.endswith("."):
            hostname += "."

        self._info = ServiceInfo(
            type_=SERVICE_TYPE,
            name=service_name,
            server=hostname,
            addresses=addresses,
            port=self._config.port,
            properties={
                "name": self._config.name,
                "version": self._version,
                "token": self._config.api_token,
                "host": host,
                "port": str(self._config.port),
            },
        )

        self._zeroconf = Zeroconf()
        self._zeroconf.register_service(self._info)
        log.info(
            "Bonjour: advertising %s on port %d",
            self._config.name,
            self._config.port,
        )

    def stop(self) -> None:
        """Unregister the service and close Zeroconf."""
        if self._zeroconf and self._info:
            try:
                self._zeroconf.unregister_service(self._info)
            except Exception:
                pass  # Best-effort during shutdown
            self._zeroconf.close()
            self._zeroconf = None
            self._info = None
            log.info("Bonjour: service unregistered")

    @staticmethod
    def _get_local_ip() -> str:
        """Get the primary local IP address (best-effort)."""
        try:
            # Connect to a public DNS to determine our outbound IP
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
                s.connect(("8.8.8.8", 80))
                return s.getsockname()[0]
        except OSError:
            return "127.0.0.1"
