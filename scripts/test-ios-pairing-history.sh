#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/tests
xcrun swiftc -swift-version 5 -parse-as-library \
  ios/RayBridge/PairingHostPolicy.swift ios/RayBridge/Pairing.swift \
  ios/Tests/PairingHistoryTests.swift \
  -o .build/tests/pairing-history-tests
.build/tests/pairing-history-tests
