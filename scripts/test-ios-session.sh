#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/tests
xcrun swiftc -swift-version 5 -parse-as-library \
  ios/RayBridge/SessionController.swift ios/Tests/SessionControllerTests.swift \
  -o .build/tests/session-controller-tests
.build/tests/session-controller-tests
