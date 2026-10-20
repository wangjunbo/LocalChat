#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/Applications/DevEco-Studio.app/Contents/tools/node/bin:$PATH"
export JAVA_HOME="/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home"
export DEVECO_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk"
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw --mode module -p product=default -p module=entry@default assembleHap --no-daemon

python3 scripts/verify-package.py
