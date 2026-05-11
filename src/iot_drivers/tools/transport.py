"""filamind-iotbox transport selector.

Implements a graceful-degradation chain so the box can talk to the
configured Odoo server regardless of how its reverse proxy is set up:

    1. WebSocket (wss://<server>/websocket)         lowest latency
    2. HTTP long-poll (POST /filamind_iot/poll)     blocks up to 30 s
    3. HTTP short-poll (POST /filamind_iot/poll_short)  every N seconds

The cached choice is persisted in /home/pi/odoo.conf under
`[iot.box] transport = websocket | longpoll | shortpoll | auto` so the
box doesn't re-probe at every boot.

This module is imported by the patched main.py via Transport.create(...)
which replaces the upstream WebsocketClient(...) call. All three
transports share the same `on_message` semantics so drivers and
communication.handle_message see no change.
"""
import logging
import threading
import urllib.parse

import requests
import websocket

# NOTE: communication is NOT imported at module level — that creates a
# circular dependency because iot_drivers.__init__ -> connection_manager
# -> main -> tools.transport, while communication is also imported via
# main. The first deploy on a real customer box hit:
#   ImportError: cannot import name 'communication' from partially
#   initialized module 'odoo.addons.iot_drivers'
# The handler is only used inside _PollingTransportBase._dispatch, so
# we defer the import to call time when the cycle has resolved.
from odoo.addons.iot_drivers.tools import helpers, system
from odoo.addons.iot_drivers.tools.system import IOT_IDENTIFIER
from odoo.addons.iot_drivers.websocket_client import (
    WebsocketClient, send_to_controller,
)

_logger = logging.getLogger(__name__)

# Disable noisy "Permanently added ..." websocket trace by default; the
# upstream WebsocketClient already enables it under DEBUG.
websocket.enableTrace(False)

CONFIG_KEY = 'transport'
DEFAULT_LONGPOLL_WAIT = 25     # server caps at 30
DEFAULT_SHORTPOLL_INTERVAL = 5
PROBE_TIMEOUT = 8


# ── Concrete transports ──────────────────────────────────────────────────

class WebSocketTransport:
    """Wrapper around the upstream WebsocketClient — keeps existing
    behaviour for boxes whose proxy supports WS properly."""

    def __init__(self, channel, server_url):
        self._client = WebsocketClient(channel)

    def start(self):
        self._client.start()

    def stop(self):
        try:
            ws = getattr(self._client, 'ws', None)
            if ws is not None:
                ws.keep_running = False
                ws.close()
        except Exception:
            _logger.exception("Failed to stop WebsocketClient")


class _PollingTransportBase(threading.Thread):
    """Common base for long-poll and short-poll transports."""

    POLL_PATH = '/filamind_iot/poll'
    POLL_BODY_DEFAULTS = {'wait_seconds': DEFAULT_LONGPOLL_WAIT}
    REQUEST_TIMEOUT = 35
    LOOP_DELAY_ON_ERROR = 5

    def __init__(self, channel, server_url):
        super().__init__(daemon=True)
        self.channel = channel
        self.server_url = server_url.rstrip('/')
        self.last_seq = 0
        self._stop = threading.Event()

    def stop(self):
        self._stop.set()

    def _build_body(self):
        return {
            'identifier': IOT_IDENTIFIER,
            'token': helpers.get_token() or '',
            'last_seq': self.last_seq,
            **self.POLL_BODY_DEFAULTS,
        }

    def run(self):
        while not self._stop.is_set():
            try:
                resp = requests.post(
                    self.server_url + self.POLL_PATH,
                    json=self._build_body(),
                    timeout=self.REQUEST_TIMEOUT,
                )
                if resp.status_code == 200:
                    self._handle_response(resp.json())
                elif resp.status_code == 401:
                    _logger.warning(
                        "%s rejected with 401 — token mismatch?",
                        self.POLL_PATH)
                    self._stop.wait(self.LOOP_DELAY_ON_ERROR)
                else:
                    _logger.warning("%s returned HTTP %s",
                                    self.POLL_PATH, resp.status_code)
                    self._stop.wait(self.LOOP_DELAY_ON_ERROR)
            except requests.exceptions.RequestException:
                _logger.exception("Polling request to %s failed", self.server_url)
                self._stop.wait(self.LOOP_DELAY_ON_ERROR)

    def _handle_response(self, data):
        for cmd in data.get('commands') or []:
            self._dispatch(cmd)
        self.last_seq = data.get('next_seq', self.last_seq)

    def _dispatch(self, cmd):
        method = cmd.get('method', 'iot_action')
        payload = cmd.get('payload') or {}
        # Same identifier filter the WebsocketClient does.
        if payload.get('iot_identifier') and \
                payload['iot_identifier'] != IOT_IDENTIFIER:
            return
        try:
            # Lazy import — see module-top NOTE about the circular dep.
            from odoo.addons.iot_drivers import communication
            result = communication.handle_message(method, 'http', **payload)
        except Exception:
            _logger.exception("Driver dispatch failed for %s", method)
            return
        if result:
            try:
                send_to_controller(result)
            except Exception:
                _logger.exception("send_to_controller failed")


class LongPollTransport(_PollingTransportBase):
    """Server holds the connection open up to 30 s — wakes on any new
    command. Best fallback when WebSocket is broken."""
    POLL_PATH = '/filamind_iot/poll'


class ShortPollTransport(_PollingTransportBase):
    """Server returns immediately; the box sleeps `interval` seconds
    between cycles. For environments that block long-running HTTP
    connections (some hardened LBs)."""
    POLL_PATH = '/filamind_iot/poll_short'
    POLL_BODY_DEFAULTS = {}
    REQUEST_TIMEOUT = 10
    LOOP_DELAY_ON_ERROR = DEFAULT_SHORTPOLL_INTERVAL

    def __init__(self, channel, server_url, interval=DEFAULT_SHORTPOLL_INTERVAL):
        super().__init__(channel, server_url)
        self.interval = interval

    def _handle_response(self, data):
        super()._handle_response(data)
        self._stop.wait(self.interval)


# ── Transport selector ──────────────────────────────────────────────────

class Transport:
    """Factory that picks the best transport at boot time."""

    @classmethod
    def create(cls, channel, server_url=None):
        if server_url is None:
            server_url = helpers.get_odoo_server_url() or ''
        if not server_url:
            _logger.warning("Transport.create called with no server URL — "
                            "falling back to upstream WebsocketClient")
            return WebSocketTransport(channel, '')

        cached = (system.get_conf(CONFIG_KEY) or 'auto').strip().lower()
        if cached == 'websocket':
            _logger.info("Transport: cached choice = websocket")
            return WebSocketTransport(channel, server_url)
        if cached == 'longpoll':
            _logger.info("Transport: cached choice = longpoll")
            return LongPollTransport(channel, server_url)
        if cached == 'shortpoll':
            _logger.info("Transport: cached choice = shortpoll")
            return ShortPollTransport(channel, server_url)

        # auto — probe and persist
        if cls._probe_websocket(server_url):
            _logger.info("Transport probe: websocket OK -> using WS")
            system.update_conf({CONFIG_KEY: 'websocket'})
            return WebSocketTransport(channel, server_url)
        _logger.warning("Transport probe: websocket FAILED")

        if cls._probe_longpoll(server_url):
            _logger.info("Transport probe: longpoll OK -> using long-poll")
            system.update_conf({CONFIG_KEY: 'longpoll'})
            return LongPollTransport(channel, server_url)
        _logger.warning("Transport probe: longpoll FAILED")

        _logger.warning("Transport probe: falling back to short-poll")
        system.update_conf({CONFIG_KEY: 'shortpoll'})
        return ShortPollTransport(channel, server_url)

    # ── Probes ──────────────────────────────────────────────────────────
    @staticmethod
    def _probe_websocket(server_url):
        try:
            url_parsed = urllib.parse.urlsplit(server_url)
            scheme = url_parsed.scheme.replace('http', 'ws', 1)
            ws_url = urllib.parse.urlunsplit(
                (scheme, url_parsed.netloc, 'websocket', '', ''))
            ws = websocket.create_connection(ws_url, timeout=PROBE_TIMEOUT)
            ws.close()
            return True
        except Exception as exc:
            _logger.info("Websocket probe failed: %s", exc)
            return False

    @staticmethod
    def _probe_longpoll(server_url):
        try:
            r = requests.post(
                server_url.rstrip('/') + '/filamind_iot/poll_short',
                json={'identifier': '', 'token': '', 'last_seq': 0},
                timeout=PROBE_TIMEOUT,
            )
            # 401 means the endpoint exists but rejected our empty creds.
            # That's exactly what we need to confirm reachability.
            return r.status_code in (200, 401)
        except requests.exceptions.RequestException as exc:
            _logger.info("Longpoll probe failed: %s", exc)
            return False
