#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/tests
xcrun swiftc -swift-version 5 -parse-as-library \
  ios/RayBridge/CaptureSourcePolicy.swift ios/Tests/CaptureSourcePolicyTests.swift \
  -o .build/tests/capture-source-tests
.build/tests/capture-source-tests
