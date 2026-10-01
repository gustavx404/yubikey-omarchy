import io
import random
import string
import sys
import unittest
import unicodedata
from unittest.mock import patch

import ykbridge


class BridgeProtocolTests(unittest.TestCase):
    def read_request(self, action: str, raw: bytes):
        stream = io.TextIOWrapper(io.BytesIO(raw))
        with patch.object(sys, "stdin", stream):
            return ykbridge.read_request(action)

    def test_accepts_only_the_list_schema(self):
        result = self.read_request("list", b'{"schema":1,"passwords":{}}\n')
        self.assertEqual(result, {"schema": 1, "passwords": {}})

    def test_icon_actions_accept_only_the_fixed_schema(self):
        for action in ("icon-import", "icon-list", "icon-clear"):
            self.assertEqual(self.read_request(action, b'{"schema":1}\n'), {"schema": 1})
            with self.subTest(action=action), self.assertRaises(ValueError):
                self.read_request(action, b'{"schema":1,"path":"/tmp/unexpected"}\n')

    def test_rejects_unexpected_and_duplicate_fields(self):
        invalid = (
            b'{"schema":1,"passwords":{},"debug":true}\n',
            b'{"schema":1,"schema":1,"passwords":{}}\n',
            b'{"schema":1,"passwords":{}}\n{}\n',
            b'{"schema":true,"passwords":{}}\n',
            b'{"schema":1,"passwords":{},"value":NaN}\n',
        )
        for request in invalid:
            with self.subTest(request=request[:48]), self.assertRaises(ValueError):
                self.read_request("list", request)

    def test_rejects_bad_code_fields(self):
        request = b'{"schema":1,"keyId":"key","accountId":"xyz","password":"","clearTimeoutSeconds":30}\n'
        with self.assertRaises(ValueError):
            self.read_request("code", request)

    def test_accepts_only_supported_code_timeouts(self):
        for timeout in (30, 60, 120):
            request = (
                b'{"schema":1,"keyId":"key","accountId":"00112233","password":"",'
                + f'"clearTimeoutSeconds":{timeout}'.encode()
                + b'}\n'
            )
            result = self.read_request("code", request)
            self.assertEqual(result["clearTimeoutSeconds"], timeout)

        for timeout in (45, 300):
            request = (
                b'{"schema":1,"keyId":"key","accountId":"00112233","password":"",'
                + f'"clearTimeoutSeconds":{timeout}'.encode()
                + b'}\n'
            )
            with self.assertRaises(ValueError):
                self.read_request("code", request)

    def test_rejects_oversized_requests_and_password_controls(self):
        oversized = b'{"schema":1,"passwords":{}}' + b" " * ykbridge.MAX_REQUEST_BYTES + b"\n"
        with self.assertRaises(ValueError):
            self.read_request("list", oversized)
        controlled = b'{"schema":1,"passwords":{"00112233":"bad\\u001bvalue"}}\n'
        with self.assertRaises(ValueError):
            self.read_request("list", controlled)

    def test_label_cleaning_bounds_and_removes_controls(self):
        raw = "<b>Issuer</b>\x1b\u202e\x00" + "x" * 500
        cleaned = ykbridge.clean_label(raw)
        self.assertLessEqual(len(cleaned), ykbridge.MAX_LABEL_LENGTH)
        self.assertFalse(any(unicodedata.category(char).startswith("C") for char in cleaned))

    def test_password_validation_uses_a_wipeable_derived_key(self):
        class StubOath:
            received_type = None

            def derive_key(self, password):
                self.asserted_password = password
                return b"derived-key"

            def validate(self, key):
                self.received_type = type(key)

        oath = StubOath()
        self.assertTrue(ykbridge.validate_password(oath, "example-password"))
        self.assertEqual(oath.received_type, bytearray)
        self.assertEqual(oath.asserted_password, "example-password")

    def test_fuzzes_labels_with_arbitrary_unicode_and_controls(self):
        rng = random.Random(404)
        alphabet = string.printable + "界" + "\u202e\u2066\x00\x1b"
        for _ in range(2000):
            raw = "".join(rng.choice(alphabet) for _ in range(rng.randrange(0, 512)))
            cleaned = ykbridge.clean_label(raw)
            self.assertLessEqual(len(cleaned), ykbridge.MAX_LABEL_LENGTH)
            self.assertFalse(any(unicodedata.category(char).startswith("C") for char in cleaned))


if __name__ == "__main__":
    unittest.main()
