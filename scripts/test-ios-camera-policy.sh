#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/tests
xcrun swiftc -swift-version 5 -parse-as-library \
  ios/RayBridge/CameraImagePolicy.swift ios/Tests/CameraImagePolicyTests.swift \
  -o .build/tests/camera-image-policy-tests
.build/tests/camera-image-policy-tests
