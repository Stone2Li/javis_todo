#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
"$repo_root/tools/swift.sh" test --jobs 2
"$repo_root/tools/swift.sh" run --skip-build domain-fixtures /repo/fixtures/domain/m01.json
