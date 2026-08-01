# -*- coding: utf-8 -*-
"""Tests for the configurable session cookie SameSite attribute."""

import os
import sys
import unittest
from unittest.mock import MagicMock, patch

# Keep this test runnable when optional LLM runtime deps are not installed.
try:
    import litellm  # noqa: F401
except ModuleNotFoundError:
    sys.modules["litellm"] = MagicMock()

from starlette.requests import Request

from api.v1.endpoints import auth as auth_endpoint


def _make_request(scheme: str = "http") -> Request:
    return Request(
        {
            "type": "http",
            "method": "GET",
            "path": "/",
            "headers": [],
            "scheme": scheme,
            "server": ("testserver", 80),
            "query_string": b"",
        }
    )


class CookieSameSiteTestCase(unittest.TestCase):
    """SameSite must stay 'lax' by default and force Secure when set to 'none'."""

    def test_defaults_to_lax(self):
        with patch.dict(os.environ, {"TRUST_X_FORWARDED_FOR": "false"}, clear=False):
            os.environ.pop("ADMIN_SESSION_COOKIE_SAMESITE", None)
            params = auth_endpoint._cookie_params(_make_request())

        self.assertEqual(params["samesite"], "lax")

    def test_none_forces_secure_even_on_http_scheme(self):
        env = {
            "TRUST_X_FORWARDED_FOR": "false",
            "ADMIN_SESSION_COOKIE_SAMESITE": "none",
        }
        with patch.dict(os.environ, env, clear=False):
            params = auth_endpoint._cookie_params(_make_request(scheme="http"))

        self.assertEqual(params["samesite"], "none")
        self.assertTrue(params["secure"])

    def test_strict_is_accepted_and_does_not_force_secure(self):
        env = {
            "TRUST_X_FORWARDED_FOR": "false",
            "ADMIN_SESSION_COOKIE_SAMESITE": "Strict",
        }
        with patch.dict(os.environ, env, clear=False):
            params = auth_endpoint._cookie_params(_make_request(scheme="http"))

        self.assertEqual(params["samesite"], "strict")
        self.assertFalse(params["secure"])

    def test_invalid_value_falls_back_to_lax(self):
        env = {
            "TRUST_X_FORWARDED_FOR": "false",
            "ADMIN_SESSION_COOKIE_SAMESITE": "bogus",
        }
        with patch.dict(os.environ, env, clear=False), \
             patch.object(auth_endpoint.logger, "warning") as warning:
            params = auth_endpoint._cookie_params(_make_request())

        self.assertEqual(params["samesite"], "lax")
        warning.assert_called_once()


if __name__ == "__main__":
    unittest.main()
