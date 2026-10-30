#!/bin/zsh
# Run every behaviour test against a copy of the reader and a verification build.
# Needs macOS with the Xcode Command Line Tools; uses synthetic data on 127.0.0.1 only.
set -euo pipefail
ROOT="${0:A:h:h}"
# Inside the ignored build/ folder: the system temp folder sits behind the /var -> /private/var
# link, which the app's path guard cannot resolve for files it has yet to create.
mkdir -p "${ROOT}/build"
export USAGE_TEST_ROOT="$(mktemp -d "${ROOT}/build/test-root.XXXXXX")"
USAGE_TEST_ROOT="${USAGE_TEST_ROOT:A}"
trap 'rm -rf "$USAGE_TEST_ROOT"' EXIT
READER="${USAGE_TEST_ROOT}/reader/statusline.sh"
mkdir -p "${READER:h}"
cp "${ROOT}/statusline/statusline.sh" "$READER"
"${ROOT}/build-provider.sh" --test --reader "$READER" --output "${USAGE_TEST_ROOT}/UsageVerification.app" >/dev/null

failed=0
run() {
 print -- "== $1"
 python3 "${ROOT}/tests/$1" "${@:2}" || failed=1
}
run test_reader_contracts.py --script "$READER" --out "${USAGE_TEST_ROOT}/out/contracts"
run test_reader_windows.py --script "$READER" --out "${USAGE_TEST_ROOT}/out/windows"
run test_throttle.py --script "$READER" --out "${USAGE_TEST_ROOT}/out/throttle"
run test_request_log.py --script "$READER" --out "${USAGE_TEST_ROOT}/out/request-log"
run test_app_rules.py --app "${USAGE_TEST_ROOT}/UsageVerification.app" --out "${USAGE_TEST_ROOT}/out/app-rules"
(( failed )) && { print -u2 'Some tests failed.'; exit 1 }
print 'All tests passed.'
