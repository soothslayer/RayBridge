#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/tests
xcrun swiftc -swift-version 5 -parse-as-library \
  ios/RayBridge/AnswerStreamPolicy.swift ios/Tests/AnswerStreamPolicyTests.swift \
  -o .build/tests/answer-stream-tests
.build/tests/answer-stream-tests
