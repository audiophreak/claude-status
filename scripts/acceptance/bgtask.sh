#!/bin/sh
# Harmless test task for acceptance runs: sleep N seconds, print a marker, exit with code C.
sleep "${1:-10}"
echo "cs-bgtask-done ${1:-10}"
exit "${2:-0}"
