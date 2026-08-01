# -*- coding: utf-8 -*-
"""Auth middleware must let CORS preflight requests through.

Browsers send `OPTIONS` preflight without credentials by design, so rejecting
them with 401 makes every cross-origin request fail: the response carries no
CORS headers and the browser reports an opaque "Failed to fetch". Same-origin
clients (web, desktop) never send preflight, so this only surfaces for the
mobile app, whose WebView origin is https://localhost.
"""

import asyncio
import sys
import unittest
from unittest.mock import AsyncMock, MagicMock, patch

# Keep this test runnable when optional LLM runtime deps are not installed.
try:
    import litellm  # noqa: F401
except ModuleNotFoundError:
    sys.modules["litellm"] = MagicMock()

from fastapi.responses import Response
from starlette.requests import Request

from api.middlewares.auth import AuthMiddleware


def _request(method: str, path: str) -> Request:
    return Request(
        {
            "type": "http",
            "method": method,
            "path": path,
            "headers": [],
            "query_string": b"",
            "scheme": "https",
            "server": ("testserver", 443),
            "root_path": "",
        }
    )


def _dispatch(method: str, path: str) -> Response:
    middleware = AuthMiddleware(app=MagicMock())
    with patch("api.middlewares.auth.is_auth_enabled", return_value=True):
        return asyncio.run(
            middleware.dispatch(
                _request(method, path),
                AsyncMock(return_value=Response(status_code=200)),
            )
        )


class AuthMiddlewarePreflightTestCase(unittest.TestCase):
    """OPTIONS must reach CORSMiddleware; other verbs stay protected."""

    def test_preflight_on_protected_path_is_not_rejected(self):
        response = _dispatch("OPTIONS", "/api/v1/agent/chat/stream")

        self.assertNotEqual(response.status_code, 401)
        self.assertEqual(response.status_code, 200)

    def test_preflight_on_other_protected_paths_is_not_rejected(self):
        for path in ("/api/v1/analysis/run", "/api/v1/portfolio/accounts"):
            with self.subTest(path=path):
                self.assertNotEqual(_dispatch("OPTIONS", path).status_code, 401)

    def test_post_without_session_is_still_rejected(self):
        """The actual request still requires a session — only preflight is exempt."""
        self.assertEqual(_dispatch("POST", "/api/v1/agent/chat/stream").status_code, 401)

    def test_get_without_session_is_still_rejected(self):
        self.assertEqual(_dispatch("GET", "/api/v1/history/reports").status_code, 401)


if __name__ == "__main__":
    unittest.main()
