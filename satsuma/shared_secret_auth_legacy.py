"""Minimal legacy Synapse password provider for mautrix double puppeting.

The mautrix-imessage build on lime uses the legacy shared-secret scheme: the
password is an HMAC-SHA512 of the full user ID, keyed with the shared secret.
Synapse 1.163 calls legacy password_providers with
``__init__(config, account_handler)`` and ``check_password(username, password)``.
The packaged shared-secret-auth plugin uses the newer provider API, so this
small provider implements the legacy hook directly. The raw shared secret is
also accepted for direct diagnostics.
"""

import hashlib
import hmac
from typing import Optional


class SharedSecretAuthProvider:
    def __init__(self, config, account_handler):
        self.shared_secret = config["shared_secret"]
        self.account_handler = account_handler

    async def check_password(self, username: str, password: str) -> Optional[str]:
        full_user_id = self.account_handler.get_qualified_user_id(username)
        expected = hmac.new(
            self.shared_secret.encode("utf-8"),
            full_user_id.encode("utf-8"),
            hashlib.sha512,
        ).hexdigest()
        if hmac.compare_digest(password, expected) or hmac.compare_digest(
            password, self.shared_secret
        ):
            return full_user_id
        return None
