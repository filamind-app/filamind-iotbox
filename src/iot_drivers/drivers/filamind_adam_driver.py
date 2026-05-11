"""Adam Equipment AGN-protocol scale driver for the filamind-iotbox.

Pairs with the server-side `filamind_pos_iot_adam_scale` addon. The
server sends an iot_action payload like:

    {'action': 'adam_zero',  'family': 'cpwplus', 'baud': '9600'}
    {'action': 'adam_tare',  'family': 'cpwplus', 'baud': '9600'}
    {'action': 'read_weight', 'family': 'cpwplus', 'baud': '9600'}

AGN protocol (ASCII over RS-232, 8/N/1):
    Z\\r        zero
    T\\r        tare
    P\\r        print/poll current weight
    Response:   "  +123.4 g\\r\\n"  (Adam framing: sign, value, unit)

The server captures the parsed response and writes it back via
the regular iot.command.queue completion path.
"""
import logging
import re
import time

from odoo.addons.iot_drivers.driver import Driver

_logger = logging.getLogger(__name__)

# Regex: optional sign, number, unit. Tolerates Adam's variable padding.
_WEIGHT_RE = re.compile(
    r'^\s*([+-]?\d+(?:\.\d+)?)\s*(g|kg|lb|oz|t)?',
    re.IGNORECASE,
)


def parse_adam_weight(raw):
    """Return (weight_float, unit) or (None, None) on parse failure."""
    if not raw:
        return None, None
    m = _WEIGHT_RE.match(raw.replace('\r', '').replace('\n', '').strip())
    if not m:
        return None, None
    try:
        return float(m.group(1)), (m.group(2) or 'g').lower()
    except (TypeError, ValueError):
        return None, None


class FilamindAdamScaleDriver(Driver):
    """AGN-protocol Adam Equipment scale driver."""

    connection_type = 'serial'
    priority = 10

    @classmethod
    def supported(cls, device):
        """Adam scales typically expose a generic FTDI / Prolific USB-Serial
        bridge (VID 0403 or 067B). The actual brand-detection is by
        product-name lookup at pair time. Here we accept any serial
        device whose vendor matches and let `family` from the payload
        decide how to talk to it."""
        vid = (device.get('VENDOR_ID') or '').lower()
        return vid in ('0403', '067b', '1a86')

    def __init__(self, identifier, device):
        super().__init__(identifier, device)
        self.device_type = 'scale'
        self.device_connection = 'serial'
        self.device_name = device.get('name') or 'Adam Scale'
        self.family = 'cpwplus'

    def action(self, data):
        try:
            action = (data or {}).get('action') or ''
            self.family = data.get('family') or self.family
            baud = int(data.get('baud') or '9600')
            # The parent class typically owns self.dev (a serial.Serial
            # instance opened in __init__). If it doesn't auto-reconfig
            # baud, we adjust it here:
            if hasattr(self, 'dev') and self.dev:
                try:
                    self.dev.baudrate = baud
                except Exception:
                    pass
            if action == 'adam_zero':
                return self._send_cmd(b'Z\r', expect_response=False)
            if action == 'adam_tare':
                return self._send_cmd(b'T\r', expect_response=False)
            if action in ('adam_read', 'read_weight', 'read_once'):
                return self._read_weight()
            if action == 'test_connection':
                return {'status': 'ok', 'driver': 'filamind_adam',
                        'family': self.family, 't': time.time()}
            return {'status': 'error',
                    'message': 'unknown action: %s' % action}
        except Exception as exc:
            _logger.exception('FilamindAdamScaleDriver.action failed')
            return {'status': 'error', 'message': str(exc)[:500]}

    # ── AGN protocol ──────────────────────────────────────────────────
    def _send_cmd(self, payload, expect_response=True):
        if not hasattr(self, 'dev') or not self.dev:
            return {'status': 'error', 'message': 'no serial device open'}
        try:
            self.dev.write(payload)
            self.dev.flush()
        except Exception as exc:
            return {'status': 'error', 'message': 'write failed: %s' % exc}
        if not expect_response:
            return {'status': 'ok', 'sent': payload.decode('ascii',
                                                            errors='ignore')}
        # 1.5s should cover any Adam scale's latency.
        deadline = time.monotonic() + 1.5
        buf = b''
        while time.monotonic() < deadline:
            try:
                chunk = self.dev.read(64)
            except Exception:
                chunk = b''
            if chunk:
                buf += chunk
                if b'\n' in buf or b'\r' in buf:
                    break
        return {'status': 'ok',
                'raw': buf.decode('ascii', errors='replace')}

    def _read_weight(self):
        resp = self._send_cmd(b'P\r', expect_response=True)
        if resp.get('status') != 'ok':
            return resp
        weight, unit = parse_adam_weight(resp.get('raw') or '')
        if weight is None:
            return {'status': 'error',
                    'message': 'unparseable AGN response',
                    'raw': resp.get('raw')}
        return {
            'status': 'ok',
            'weight': weight,
            'unit': unit,
            'raw': resp.get('raw'),
        }
