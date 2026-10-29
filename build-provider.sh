#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h}"
APP=''
TEST=0
READER=''
while (( $# )); do
 case "$1" in
  --output) APP="$2"; shift 2;;
  --test) TEST=1; shift;;
  --reader) READER="$2"; shift 2;;
  *) print -u2 'Usage: build-provider.sh --output ABSOLUTE_PATH [--reader PATH] [--test --reader PATH]'; exit 2;;
 esac
done
[[ -n "$APP" && "$APP" == /* && "$APP" == *.app ]] || { print -u2 'Explicit absolute .app output required'; exit 2; }
APP="${APP:A}"
for protected in "${ROOT}/UsageTouchBar.app" "${HOME}/Applications/UsageTouchBar.app"; do
 protected="${protected:A}"
 [[ "$APP" != "$protected" && "$APP" != "$protected/"* ]] \
  || { print -u2 'Cannot build in installed bundle'; exit 2; }
done
FLAGS=()
if (( TEST )); then
 WORK="${USAGE_TEST_ROOT:-}"
 [[ "$WORK" == /* ]] || { print -u2 'Test mode needs USAGE_TEST_ROOT set to an absolute path'; exit 2; }
 WORK="${WORK:A}"
 [[ "${APP:A}" == "${WORK}/"* && "${READER:A}" == "${WORK}/"* && -x "$READER" ]] || { print -u2 'Test outputs and reader must be under execution artifacts'; exit 2; }
 FLAGS=(-D PROVIDER_TEST)
else
 # The app runs this reader and watches the cache beside it; default is the copy in this repository.
 READER="${READER:-${ROOT}/statusline/statusline.sh}"
 [[ -f "$READER" && -x "$READER" ]] || { print -u2 "Reader not found or not executable: ${READER}"; exit 2; }
fi
# The launcher is nested in the app and finds the UI from its own location.
LAUNCHER_APP="${APP}/Contents/Library/LoginItems/UsageTouchBarLauncher.app"
mkdir -p "${APP}/Contents/MacOS" "${LAUNCHER_APP}/Contents/MacOS"
cp "${ROOT}/Info.plist" "${APP}/Contents/Info.plist"
cp "${ROOT}/launcher/Info.plist" "${LAUNCHER_APP}/Contents/Info.plist"
(( TEST )) || plutil -insert UsageReaderPath -string "${READER:A}" "${APP}/Contents/Info.plist"
if (( TEST )); then
 /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.agents.usagetouchbar.provider-verification' "${APP}/Contents/Info.plist"
 /usr/libexec/PlistBuddy -c 'Set :CFBundleName UsageVerification' "${APP}/Contents/Info.plist"
 /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.agents.usagetouchbar.provider-verification.launcher' "${LAUNCHER_APP}/Contents/Info.plist"
fi
SDK="$(xcrun --show-sdk-path)"
xcrun swiftc -O -parse-as-library -target arm64-apple-macosx13.0 -sdk "$SDK" \
 -framework AppKit -framework UserNotifications -framework Security -F /System/Library/PrivateFrameworks -framework DFRFoundation \
 -import-objc-header "${ROOT}/TouchBarPrivate.h" "${FLAGS[@]}" \
 -o "${APP}/Contents/MacOS/UsageTouchBar" "${ROOT}/provider-ui/main.swift" "${ROOT}/provider-ui/UsageNotifications.swift" "${ROOT}/provider-ui/Lifecycle.swift"
xcrun swiftc -O -parse-as-library -target arm64-apple-macosx13.0 -sdk "$SDK" \
 -framework AppKit -framework Security "${FLAGS[@]}" \
 -o "${LAUNCHER_APP}/Contents/MacOS/UsageTouchBarLauncher" "${ROOT}/provider-ui/Lifecycle.swift" "${ROOT}/launcher/main.swift"
# Inner bundle first, so the outer signature seals a signed launcher.
codesign --sign - --force "$LAUNCHER_APP"
codesign --sign - --force "$APP"
codesign --verify --deep --strict "$APP"
print "built ${APP}"
