#!/bin/bash
# e2e extension step: proves script steps run from the config repo with
# the devseed environment.
set -euo pipefail
echo "config=$DEVSEED_CONFIG_DIR stack=$DEVSEED_STACK" >"$HOME/.devseed-e2e-marker"
