#!/bin/zsh
# Build the app into ~/Applications and run it at login. --uninstall removes both.
set -euo pipefail
ROOT="${0:A:h}"
LABEL=local.agents.usagetouchbar
APP="${HOME}/Applications/UsageTouchBar.app"
EXE="${APP}/Contents/MacOS/UsageTouchBar"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
DOMAIN="gui/$(id -u)"

loaded_program() { launchctl print "${DOMAIN}/${LABEL}" 2>/dev/null | awk -F' = ' '/^\tprogram = /{print $2; exit}'; }
plist_program() { [[ -f "$PLIST" ]] && plutil -extract ProgramArguments.0 raw "$PLIST" 2>/dev/null || true; }

# Never take over an agent of the same name that runs a different copy.
for current in "$(loaded_program)" "$(plist_program)"; do
 [[ -z "$current" || "$current" == "$EXE" ]] || { print -u2 "${LABEL} already runs ${current}; leaving it alone."; exit 1; }
done

if [[ "${1:-}" == --uninstall ]]; then
 launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
 rm -f "$PLIST"
 rm -rf "$APP"
 print 'Removed UsageTouchBar.'
 exit 0
fi

xcrun --find swiftc >/dev/null 2>&1 || { print -u2 'Install the Xcode Command Line Tools first: xcode-select --install'; exit 1; }
[[ -x /usr/bin/python3 ]] || { print -u2 'python3 is missing; it comes with the Xcode Command Line Tools.'; exit 1; }

mkdir -p "${APP:h}" "${PLIST:h}"

# Build and verify the replacement beside the installed app first, so a failed build
# never touches the running agent.
STAGE="$(mktemp -d "${APP:h}/.UsageTouchBar-install.XXXXXX")"
preparing=0
trap 'rm -rf "$STAGE"; if (( preparing )) && [[ -n "${RECOVERY:-}" ]]; then rm -rf "$RECOVERY"; fi' EXIT
NEW_APP="${STAGE}/UsageTouchBar.app"
"${ROOT}/build-provider.sh" --output "$NEW_APP"
[[ -x "${NEW_APP}/Contents/MacOS/UsageTouchBar" ]] || { print -u2 'The new build has no executable; nothing was changed.'; exit 1; }
[[ "$(plutil -extract UsageReaderPath raw "${NEW_APP}/Contents/Info.plist")" == "${ROOT}/statusline/statusline.sh" ]] \
 || { print -u2 'The new build points at the wrong reader; nothing was changed.'; exit 1; }
cat > "${STAGE}/agent.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>KeepAlive</key>
	<true/>
	<key>Label</key>
	<string>${LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${EXE}</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>10</integer>
</dict>
</plist>
PLIST
plutil -lint -s "${STAGE}/agent.plist"

# Rollback state is prepared before anything is stopped. It lives outside STAGE, so the
# exit cleanup can never delete it once the swap begins; it is removed after a clean install
# or restore, and also when preparation fails before anything has been stopped.
RECOVERY="$(mktemp -d "${TMPDIR:-/tmp}/usagetouchbar-recovery.XXXXXX")"
preparing=1
was_loaded=0
[[ -z "$(loaded_program)" ]] || was_loaded=1
if [[ -e "$APP" ]]; then cp -Rp "$APP" "${RECOVERY}/previous.app"; fi
if [[ -f "$PLIST" ]]; then cp -p "$PLIST" "${RECOVERY}/previous.plist"; fi
cp "${STAGE}/agent.plist" "${RECOVERY}/restart.plist"   # restarts a loaded agent that had no plist

swap() {
 if (( was_loaded )); then launchctl bootout "${DOMAIN}/${LABEL}" || return 1; fi
 rm -rf "$APP" || return 1
 mv "$NEW_APP" "$APP" || return 1
 cp "${STAGE}/agent.plist" "$PLIST" || return 1
 launchctl bootstrap "$DOMAIN" "$PLIST" || return 1
}

restore() {
 local ok=1
 rm -rf "$APP" || ok=0
 if [[ -e "${RECOVERY}/previous.app" ]]; then cp -Rp "${RECOVERY}/previous.app" "$APP" || ok=0; fi
 if [[ -f "${RECOVERY}/previous.plist" ]]; then cp -p "${RECOVERY}/previous.plist" "$PLIST" || ok=0
 elif (( was_loaded )); then cp "${RECOVERY}/restart.plist" "$PLIST" || ok=0
 else rm -f "$PLIST" || ok=0
 fi
 if (( ok && was_loaded )); then launchctl bootstrap "$DOMAIN" "$PLIST" || ok=0; fi
 if (( ok )); then
  rm -rf "$RECOVERY"
  print -u2 'The previous install is back in place.'
 else
  print -u2 "Restoring the previous install failed. Its files are kept in ${RECOVERY} (previous.app, previous.plist, restart.plist)."
 fi
}

preparing=0
if ! swap; then
 print -u2 'Installing the new build failed; restoring the previous install.'
 restore
 exit 1
fi
rm -rf "$RECOVERY"
print "Installed ${APP}. It reads usage through ${ROOT}/statusline/statusline.sh, so keep this folder where it is (or run ./install.sh again after moving it)."
