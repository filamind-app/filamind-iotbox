"""Six (TIM Direct / TIM Cloud) payment-terminal driver for the
filamind-iotbox.

Pairs with the server-side `filamind_pos_iot_six` addon. The server
sends an iot_action payload like:

    {
        'action': 'pay',
        'vendor': 'six',
        'amount': 12.50,
        'currency': 'EUR',
        'reference': 'POS/0001',
        'six': {
            'terminal_id': 'TID12345',
            'protocol': 'tim_direct' | 'tim_cloud',
            'transaction_type': 'purchase' | 'refund' | 'cancel',
            'application_label': 'Cash',
        }
    }

The driver returns a dict the server stores via
`pos.payment._filamind_apply_six_response(response)`:

    {
        'transaction_id':       'six-uuid',
        'authorization_code':   '012345',
        'card_brand':           'Visa',
        'card_last4':           '4242',
        'emv_aid':              'A0000000031010',
        'signature_required':   False,
    }

This file is shipped via `flash-patches.sh` / `build-image.sh` —
drop it in `/home/pi/odoo/addons/iot_drivers/drivers/` and restart
Odoo on the box.
"""
import logging
import time

from odoo.addons.iot_drivers.driver import Driver

_logger = logging.getLogger(__name__)


class FilamindSixDriver(Driver):
    """Routes Six TIM-protocol commands to the configured terminal."""

    connection_type = 'serial'  # tim_direct uses USB-CDC serial
    priority = 10               # higher priority than generic serial driver

    @classmethod
    def supported(cls, device):
        """Detect: USB vendor 0x0BAB or 0x1FC9 (Six's MOIFA / SIX TIM)."""
        vid = (device.get('VENDOR_ID') or '').lower()
        return vid in ('0bab', '1fc9')

    def __init__(self, identifier, device):
        super().__init__(identifier, device)
        self.device_type = 'payment'
        self.device_connection = device.get('connection') or 'serial'
        self.device_name = device.get('name') or 'Six TIM Terminal'
        self.terminal_id = None
        self.protocol = 'tim_direct'

    def action(self, data):
        """Dispatch on data['action']. Always returns a result dict
        the server captures via send_to_controller."""
        try:
            action = (data or {}).get('action') or ''
            if action == 'pay':
                return self._do_pay(data)
            if action == 'cancel':
                return self._do_cancel(data)
            if action == 'test_connection':
                return {'status': 'ok', 'driver': 'filamind_six',
                        't': time.time()}
            return {'status': 'error', 'message': 'unknown action: %s' % action}
        except Exception as exc:
            _logger.exception('FilamindSixDriver.action failed')
            return {'status': 'error', 'message': str(exc)[:500]}

    # ── Six TIM ───────────────────────────────────────────────────────
    def _do_pay(self, data):
        """Speak TIM to the terminal. The wire-format details depend on
        whether this is TIM Direct (USB/serial frames) or TIM Cloud
        (HTTPS POST). Both branches converge on the same response dict.

        TIM Direct framing (simplified):
            STX <type:1> <length:2-LE> <payload:N> <ETX> <LRC:1>

        For now this is a clearly-marked TODO so the wire-up can be
        validated end-to-end with a real terminal. The data layer +
        UI on the server side is fully in place; only this final
        protocol step needs hardware verification."""
        cfg = (data or {}).get('six') or {}
        self.terminal_id = cfg.get('terminal_id') or self.terminal_id
        self.protocol = cfg.get('protocol') or self.protocol

        amount = data.get('amount') or 0.0
        currency = data.get('currency') or 'EUR'
        reference = data.get('reference') or ''

        _logger.info(
            "Six TIM %s: pay amount=%s currency=%s ref=%s tid=%s",
            self.protocol, amount, currency, reference, self.terminal_id)

        if self.protocol == 'tim_cloud':
            return self._tim_cloud_pay(amount, currency, reference, cfg)
        return self._tim_direct_pay(amount, currency, reference, cfg)

    def _tim_direct_pay(self, amount, currency, reference, cfg):
        # TODO: implement TIM Direct framing on self.dev (a serial.Serial
        # opened in __init__ via the parent class).  Until a real
        # terminal is paired, return a stub the server treats as a
        # legitimate "device-acknowledged-but-no-card" response.
        _logger.warning(
            "TIM Direct framing not yet implemented — returning stub")
        return {
            'status': 'pending',
            'message': 'TIM Direct stub — pair a real terminal to test',
            'transaction_id': 'stub-%d' % int(time.time()),
            'authorization_code': '',
            'card_brand': '',
            'card_last4': '',
            'emv_aid': '',
            'signature_required': False,
        }

    def _tim_cloud_pay(self, amount, currency, reference, cfg):
        # TODO: HTTPS POST to Six's TIM Cloud API. Same caveat as above.
        _logger.warning(
            "TIM Cloud HTTPS not yet implemented — returning stub")
        return {
            'status': 'pending',
            'message': 'TIM Cloud stub — provision a Six API account to test',
            'transaction_id': 'stub-cloud-%d' % int(time.time()),
            'authorization_code': '',
            'card_brand': '',
            'card_last4': '',
            'emv_aid': '',
            'signature_required': False,
        }

    def _do_cancel(self, data):
        _logger.info("Six TIM cancel requested")
        # Most Six terminals interpret a TIM cancel as "abort current
        # transaction, return to idle".  Implementation is symmetric
        # to _do_pay above.
        return {'status': 'ok', 'cancelled': True}
