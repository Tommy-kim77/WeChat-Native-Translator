#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/regression
# Keep the product views and model unchanged; suppress only application startup in this fixture host.
python3 - <<'PY'
from pathlib import Path
s = Path('Sources/App.swift').read_text()
s = s.replace('@main\nstruct NativeTranslatorApp', 'struct NativeTranslatorApp')
s = s.replace('.task { await model.start(); await model.poll() }', '')
# The fixture supplies messages directly instead of starting the production polling task.
s = s.replace('await model.watchMessages(in: room)', '_ = room')
target = Path('.build/regression/App.swift')
if not target.exists() or target.read_text() != s:
    target.write_text(s)
PY
sources=()
for file in Sources/*.swift; do
    [[ "$file" == Sources/App.swift ]] || sources+=("$file")
done
xcrun swiftc -module-cache-path /private/tmp/wechat-regression-swift-cache -parse-as-library \
    "${sources[@]}" .build/regression/App.swift Tests/macOS/Regression.swift \
    -framework AppKit -framework SwiftUI -framework Translation -framework NaturalLanguage -framework Security \
    -o .build/regression/macOS-tests
.build/regression/macOS-tests
