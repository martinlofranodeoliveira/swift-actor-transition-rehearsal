#!/bin/sh
set -eu
exec python3 "${0%/*}/gate.py" test "$@"
