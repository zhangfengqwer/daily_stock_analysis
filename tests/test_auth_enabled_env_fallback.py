# -*- coding: utf-8 -*-
"""Tests for reading ADMIN_AUTH_ENABLED when no .env file is present.

Docker deployments inject configuration through ``env_file`` (container
environment variables) and deliberately do not mount ``.env`` into the
container, so auth enablement must not depend on that file existing.
"""

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

# Keep this test runnable when optional LLM runtime deps are not installed.
try:
    import litellm  # noqa: F401
except ModuleNotFoundError:
    sys.modules["litellm"] = MagicMock()

import src.auth as auth


class AuthEnabledEnvFallbackTestCase(unittest.TestCase):
    """ADMIN_AUTH_ENABLED must be honoured with and without a .env file."""

    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.tmp = Path(self.temp_dir.name)
        # _ensure_env_loaded() would pull in the real repo .env; the behaviour
        # under test is the file-vs-environment resolution, not dotenv loading.
        patcher = patch.object(auth, "_ensure_env_loaded", return_value=None)
        patcher.start()
        self.addCleanup(patcher.stop)

    def _read(self, env: dict) -> bool:
        with patch.dict(os.environ, env, clear=False):
            return auth._is_auth_enabled_from_env()

    def test_missing_env_file_falls_back_to_environment_variable(self):
        missing = self.tmp / "does-not-exist.env"

        self.assertTrue(
            self._read({"ENV_FILE": str(missing), "ADMIN_AUTH_ENABLED": "true"})
        )

    def test_missing_env_file_and_unset_variable_stays_disabled(self):
        missing = self.tmp / "does-not-exist.env"
        with patch.dict(os.environ, {"ENV_FILE": str(missing)}, clear=False):
            os.environ.pop("ADMIN_AUTH_ENABLED", None)
            self.assertFalse(auth._is_auth_enabled_from_env())

    def test_missing_env_file_accepts_alternate_truthy_spellings(self):
        missing = self.tmp / "does-not-exist.env"

        for value in ("TRUE", "1", "yes", " Yes "):
            with self.subTest(value=value):
                self.assertTrue(
                    self._read({"ENV_FILE": str(missing), "ADMIN_AUTH_ENABLED": value})
                )

    def test_existing_env_file_still_wins_over_environment_variable(self):
        """Preserves runtime toggling from the web UI, which rewrites .env."""
        env_path = self.tmp / ".env"
        env_path.write_text("ADMIN_AUTH_ENABLED=false\n", encoding="utf-8")

        self.assertFalse(
            self._read({"ENV_FILE": str(env_path), "ADMIN_AUTH_ENABLED": "true"})
        )

    def test_existing_env_file_enables_auth(self):
        env_path = self.tmp / ".env"
        env_path.write_text("ADMIN_AUTH_ENABLED=true\n", encoding="utf-8")

        with patch.dict(os.environ, {"ENV_FILE": str(env_path)}, clear=False):
            os.environ.pop("ADMIN_AUTH_ENABLED", None)
            self.assertTrue(auth._is_auth_enabled_from_env())


if __name__ == "__main__":
    unittest.main()
