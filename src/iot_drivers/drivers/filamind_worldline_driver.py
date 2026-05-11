"""Worldline (CTEP / Sips-Sherlocks) payment-terminal driver for the
filamind-iotbox.

Pairs with the server-side `filamind_pos_iot_worldline` addon. The
server sends an iot_action payload like:

    {
        'action': 'pay',
        'vendor': 'worldline',
        'amount': 12.50,
        'currency': 'EUR',
        'reference': 'POS/0001',
        'worldline': {
            'terminal_id': 'WL12345678',
            'protocol': 'ctep' | 'cless_evo',
            'transaction_type': 'purchase' | 'refund' | 'preauth' | 'capture',
            'language': 'en',
            'manual_entry_allowed': False,
            'currency_code': '978',
        }
    }

The driver returns a dict the server stores via
`pos.payment._filamind_apply_worldline_response(response)`:

    {
        'authorization_code':   '012345',
        'card_brand':           'Mastercard',
        'card_last4':           '1234',
        'emv_aid':              'A0000000041010',
        'emv_tvr':              '8080040000',
        'emv_tsi':              'F800',
        'signature_required':   False,
    }
"""
import logging
import time

from odoo.addons.iot_drivers.driver import Driver

_logger = logging.getLogger(__name__)


class FilamindWorldlineDriver(Driver):
    """Routes Worldline CTEP-protocol commands to the configured terminal."""

    connection_type = 'serial'
    priority = 10

    @classmethod
    def supported(cls, device):
        """Detect: USB vendor 0x0CCD (Worldline / Yomani / Yoximo)."""
        vid = (device.get('VENDOR_ID') or '').lower()
        return vid in ('0ccd',)

    def __init__(self, identifier, device):
        super().__init__(identifier, device)
        self.device_type = 'payment'
        self.device_connection = device.get('connection') or 'serial'
        self.device_name = device.get('name') or 'Worldline Terminal'
        self.terminal_id = None
        self.protocol = 'ctep'

    def action(self, data):
        try:
            action = (data or {}).get('action') or ''
            if action == 'pay':
                return self._do_pay(data)
            if action == 'cancel':
                return self._do_cancel(data)
            if action == 'test_connection':
                return {'status': 'ok', 'driver': 'filamind_worldline',
                        't': time.time()}
            return {'status': 'error',
                    'message': 'unknown action: %s' % action}
        except Exception as exc:
            _logger.exception('FilamindWorldlineDriver.action failed')
            return {'status': 'error', 'message': str(exc)[:500]}

    # ── Worldline CTEP ────────────────────────────────────────────────
    def _do_pay(self, data):
        """Speak CTEP to the terminal.

        CTEP framing (simplified):
            <length:4-LE> <type:2> <subtype:2> <payload:N>

        Wire-format details vary by Worldline model (Yomani XR, YoxiPOS,
        Move/2500, etc.). Payload encodes ISO 8583-style fields:
            DE 4  amount, 12 digits
            DE 22 entry mode (chip / contactless / mag / keyed)
            DE 41 terminal id
            DE 49 currency code (numeric)

        Stub implementation until paired with real hardware."""
        cfg = (data or {}).get('worldline') or {}
        self.terminal_id = cfg.get('terminal_id') or self.terminal_id
        self.protocol = cfg.get('protocol') or self.protocol

        amount = data.get('amount') or 0.0
        currency = data.get('currency') or 'EUR'
        reference = data.get('reference') or ''
        currency_code = cfg.get('currency_code') or '978'  # EUR default

        _logger.info(
            "Worldline CTEP %s: pay amount=%s currency=%s "
            "currency_code=%s ref=%s tid=%s manual=%s",
            self.protocol, amount, currency, currency_code, reference,
            self.terminal_id, cfg.get('manual_entry_allowed'))

        if not self.terminal_id:
            return {'status': 'error',
                    'message': 'no terminal_id provided in payload'}

        # TODO: real CTEP framing here. Requires the Worldline TerminalSDK
        # binary blob (LGPL-incompatible) OR a clean-room CTEP encoder.
        _logger.warning(
            "Worldline CTEP framing not yet implemented — returning stub")
        return {
            'status': 'pending',
            'message': 'CTEP stub — pair a real terminal to test',
            'authorization_code': '',
            'card_brand': '',
            'card_last4': '',
            'emv_aid': '',
            'emv_tvr': '0000000000',
            'emv_tsi': '0000',
            'signature_required': False,
        }

    def _do_cancel(self, data):
        _logger.info("Worldline CTEP cancel requested")
        return {'status': 'ok', 'cancelled': True}
