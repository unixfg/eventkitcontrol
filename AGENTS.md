# Repository agent guidance

## GitHub CLI authentication

The user's `gh` credentials exist in the host environment outside the Codex
sandbox. A sandboxed `gh auth status` or authenticated API failure shows only
that isolation boundary; it is not evidence that the credentials are missing,
invalid, or unconfigured.

When an authenticated GitHub operation is authorized and needed, use the
approved host/outside-sandbox execution path. Do not try to reauthenticate,
ask the user to recreate credentials, or repeatedly probe authentication from
inside the sandbox.
