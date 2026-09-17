#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/tests
xcrun swiftc -swift-version 5 -parse-as-library \
  ios/RayBridge/VoiceCommandPolicy.swift ios/Tests/VoiceCommandPolicyTests.swift \
  -o .build/tests/voice-command-tests
.build/tests/voice-command-tests
