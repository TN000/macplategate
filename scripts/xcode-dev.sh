#!/usr/bin/env bash
# Otevře SPZ projekt v Xcode 26 s plnou IDE podporou:
#  • Predictive Code Completion (Xcode 16+ Foundation Models on-device)
#  • SwiftUI Previews (#Preview makra)
#  • Metal Shader Debugger (Debug → Capture GPU Frame)
#  • Instruments Time Profiler + Points of Interest (OSSignpost hot paths)
#
# Workflow:
#   1. bash scripts/xcode-dev.sh                # otevře workspace v Xcode
#   2. Cmd+B v Xcode — indexuje + kompiluje
#   3. Cmd+U — spustí swift test suite
#   4. Product → Profile (Cmd+I) — spustí Instruments
#
# Předpoklad: Xcode 16+ (optimálně 26+). Predictive Code Completion vyžaduje
# Xcode 16.1+ a stažené Foundation Models (Xcode → Settings → Components).

set -euo pipefail
cd "$(dirname "$0")/.."
open -a Xcode SPZ.xcworkspace
echo "Xcode otevřen s SPZ.xcworkspace. Package.swift indexace může trvat ~30s."
echo ""
echo "Tipy:"
echo "  • Settings → Text Editing → Editing: ✓ Enable predictions (vyžaduje Foundation Models download)"
echo "  • Product → Scheme → SPZApp — default executable target"
echo "  • Debug → Capture GPU Frame — Metal shader debugger"
echo "  • Product → Profile → Time Profiler — OSSignpost swim lanes (SPZSignposts.swift kategorie)"
