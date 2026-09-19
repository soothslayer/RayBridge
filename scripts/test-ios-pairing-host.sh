#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/tests
xcrun swiftc -swift-version 5 -parse-as-library \
  ios/RayBridge/PairingHostPolicy.swift ios/Tests/PairingHostPolicyTests.swift \
  -o .build/tests/pairing-host-policy-tests
.build/tests/pairing-host-policy-tests
