#!/usr/bin/env bash
# Put a credential into the macOS keychain without it passing through a chat
# transcript, a shell history file, or a process argument list.
#
#   ./scripts/add-secret.sh crease-google-oauth-secret
#
# Prompts silently, reads once, stores, and prints only the length back. Use
# this instead of pasting a secret anywhere it will be recorded.
set -euo pipefail

SERVICE="${1:?usage: ./scripts/add-secret.sh <keychain-service-name>}"

# -s keeps it off the screen; reading into a variable rather than taking it as
# an argument keeps it out of `ps` and out of shell history.
printf 'Value for %s (input hidden): ' "$SERVICE" >&2
read -rs VALUE
printf '\n' >&2

[ -n "$VALUE" ] || { echo "empty value, nothing stored" >&2; exit 1; }

security add-generic-password -a "$USER" -s "$SERVICE" -w "$VALUE" -U
echo "stored '$SERVICE' in the keychain (${#VALUE} characters)" >&2
