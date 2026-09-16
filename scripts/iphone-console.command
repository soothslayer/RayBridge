#!/bin/bash
set -euo pipefail
if [ "$#" -ne 1 ]; then
  echo 'Usage: scripts/iphone-console.command "Your iPhone name"'
  echo 'Runs the installed RayBridge app without LLDB and streams its console here.'
  echo 'Stop the Xcode debug session first. Control-C stops this console session.'
  exit 1
fi
exec xcrun devicectl device process launch --device "$1" --terminate-existing --console org.raybridge.ios
