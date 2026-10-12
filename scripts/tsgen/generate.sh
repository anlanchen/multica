#!/usr/bin/env bash
# Regenerates Sources/MulticaCore/Generated/UpstreamTypes.swift from an
# upstream multica checkout:  scripts/tsgen/generate.sh /path/to/multica
set -euo pipefail
UP="${1:?path to multica-ai/multica checkout}/packages/core"
cd "$(dirname "$0")/../.."
python3 scripts/tsgen/gen_models.py "$UP/types" Sources/MulticaCore/Generated/UpstreamTypes.swift \
  "$UP/runtimes/cloud-runtime.ts" "$UP/runtimes/types.ts" "$UP/agents/types.ts" \
  "$UP/feedback/types.ts" "$UP/onboarding/types.ts" "$UP/api/schemas.ts" "$UP/api/client.ts"
