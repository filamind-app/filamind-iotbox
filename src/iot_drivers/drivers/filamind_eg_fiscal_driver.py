"""Egyptian Tax Authority (ETA) hardware fiscal-printer driver for the
filamind-iotbox.

Pairs with the server-side `filamind_l10n_eg_iot` addon. The server
sends an iot_action payload like:

    {
        'action': 'fiscal_print',
        'document_format': 'raw',
        'document': '... receipt body ...',
        'fiscal': {
            'kind': 'sale' | 'test' | 'refund',
            'order_ref': 'POS/0001',
            'amount_total': 100.00,
            'amount_tax':    14.00,
            'currency':     'EGP',
            'company_tax_id': '123456789',
        }
    }

The driver speaks ESC/POS with ETA-specific extensions to a
fiscal printer (Sunmi V2 fiscal, Aures Yuno fiscal, Bematech
MP-4200 TH-FI, etc.) and returns the device-issued signature:

    {
        'status': 'ok',
        'fiscal_uuid': 'UUID-from-printer',
        'fiscal_qr':   'BASE32-payload-for-QR-code',
    }

The server stores these via
`pos.order._filamind_apply_eg_fiscal_response(uuid, qr)`.
"""
import logging
import time

from odoo.addons.iot_drivers.driver import Driver

_logger = logging.getLogger(__name__)

# ESC/POS ETA-specific commands. Vendor-specific — the values below
# are the most common; override per-vendor by subclassing.
ESC = b'\x1b'
GS = b'\x1d'
ETA_BEGIN_FISCAL = ESC + b'i'      # Sunmi: begin fiscal section
ETA_END_FISCAL   = ESC + b'I'      # Sunmi: end fiscal section + sign
ETA_QUERY_UUID   = ESC + b'?u'     # query last-issued UUID
ETA_QUERY_QR     = ESC + b'?q'     # query last-issued QR payload


class FilamindEgFiscalDriver(Driver):
    """ETA hardware-fiscal-printer driver."""

    connection_type = 'serial'
    priority = 11   # higher than generic ESC/POS so we win the supported() race

    @classmethod
    def supported(cls, device):
        """Detect fiscal-capable printers by VID. Sunmi / Aures use
        their own bridges; falls back on product-name keyword match."""
        vid = (device.get('VENDOR_ID') or '').lower()
        name = (device.get('PRODUCT') or device.get('name') or '').lower()
        if vid in ('27dd', '0fe6'):     # Sunmi, Aures
            return True
        return 'fiscal' in name or 'eta' in name or 'sunmi' in name

    def __init__(self, identifier, device):
        super().__init__(identifier, device)
        self.device_type = 'printer'
        self.device_connection = device.get('connection') or 'serial'
        self.device_name = device.get('name') or 'ETA Fiscal Printer'
        self.last_uuid = ''
        self.last_qr = ''

    def action(self, data):
        try:
            action = (data or {}).get('action') or ''
            if action == 'fiscal_print':
                return self._do_fiscal_print(data)
            if action == 'print':
                # Generic fallback: print without fiscal signing
                return self._do_plain_print(data)
            if action == 'test_connection':
                return {'status': 'ok', 'driver': 'filamind_eg_fiscal',
                        't': time.time()}
            return {'status': 'error',
                    'message': 'unknown action: %s' % action}
        except Exception as exc:
            _logger.exception('FilamindEgFiscalDriver.action failed')
            return {'status': 'error', 'message': str(exc)[:500]}

    # ── ETA fiscal flow ───────────────────────────────────────────────
    def _do_fiscal_print(self, data):
        body = (data.get('document') or '').encode('cp864', errors='replace')
        cfg = (data or {}).get('fiscal') or {}
        kind = cfg.get('kind') or 'sale'

        if not hasattr(self, 'dev') or not self.dev:
            return {'status': 'error', 'message': 'no printer connection'}

        _logger.info(
            "ETA fiscal print: kind=%s ref=%s total=%s tax=%s vat_id=%s",
            kind, cfg.get('order_ref'), cfg.get('amount_total'),
            cfg.get('amount_tax'), cfg.get('company_tax_id'))

        try:
            self.dev.write(ETA_BEGIN_FISCAL)
            self.dev.write(body)
            self.dev.write(b'\n')
            self.dev.write(ETA_END_FISCAL)
            self.dev.flush()
        except Exception as exc:
            return {'status': 'error',
                    'message': 'fiscal print failed: %s' % exc}

        # Give the printer a second to sign + emit the response
        time.sleep(1.0)

        uuid = self._query(ETA_QUERY_UUID)
        qr = self._query(ETA_QUERY_QR)

        if uuid:
            self.last_uuid = uuid
        if qr:
            self.last_qr = qr

        return {
            'status': 'ok' if uuid else 'partial',
            'fiscal_uuid': uuid or self.last_uuid or '',
            'fiscal_qr':   qr or self.last_qr or '',
        }

    def _do_plain_print(self, data):
        body = (data.get('document') or '').encode('cp864', errors='replace')
        try:
            self.dev.write(body)
            self.dev.write(b'\n\n\n')
            self.dev.flush()
        except Exception as exc:
            return {'status': 'error', 'message': 'print failed: %s' % exc}
        return {'status': 'ok'}

    def _query(self, cmd, max_wait=1.0):
        """Send a query command and read up to 64 bytes of ASCII reply."""
        if not hasattr(self, 'dev') or not self.dev:
            return ''
        try:
            self.dev.write(cmd)
            self.dev.flush()
        except Exception:
            return ''
        deadline = time.monotonic() + max_wait
        buf = b''
        while time.monotonic() < deadline:
            try:
                chunk = self.dev.read(64)
            except Exception:
                chunk = b''
            if chunk:
                buf += chunk
                if b'\n' in buf or len(buf) >= 64:
                    break
        return buf.decode('ascii', errors='replace').strip()
