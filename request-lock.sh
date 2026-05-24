#!/bin/bash

set -euo pipefail
umask 077

REQUEST_FILE="/private/tmp/ironturkey-lock-request.$(id -u)"

: > "$REQUEST_FILE"
chmod 600 "$REQUEST_FILE"
