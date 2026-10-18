#!/bin/zsh
# Build the app into ~/Applications and run its launcher at login. --uninstall removes both.
set -euo pipefail
ROOT="${0:A:h}"
LABEL=local.agents.usagetouchbar
APP="${HOME}/Applications/UsageTouchBar.app"
EXE="${APP}/Contents/MacOS/UsageTouchBar"
LAUNCHER="${APP}/Contents/Library/LoginItems/UsageTouchBarLauncher.app/Contents/MacOS/UsageTouchBarLauncher"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
DOMAIN="gui/$(id -u)"
UI_RECORD="${HOME}/Library/Application Support/UsageTouchBar/ui-instance.json"

# Empty output, not a failure, when the agent is not loaded (pipefail would otherwise end the script).
loaded_program() { launchctl print "${DOMAIN}/${LABEL}" 2>/dev/null | awk -F' = ' '/^\tprogram = /{print $2; exit}' || true; }
loaded_pid() { launchctl print "${DOMAIN}/${LABEL}" 2>/dev/null | awk -F' = ' '/^\tpid = /{print $2; exit}' || true; }
plist_program() { [[ -f "$PLIST" ]] && plutil -extract ProgramArguments.0 raw "$PLIST" 2>/dev/null || true; }

# Never take over an agent of the same name that runs a different copy. Installs from before
# the launcher ran the UI directly; both belong to this app.
for current in "$(loaded_program)" "$(plist_program)"; do
 [[ -z "$current" || "$current" == "$EXE" || "$current" == "$LAUNCHER" ]] \
  || { print -u2 "${LABEL} already runs ${current}; leaving it alone."; exit 1; }
done

# launchctl bootout returns before the job's process has exited, and bootstrapping the same
# label in that window fails with error 5. Wait until the label is gone and the process exited.
stop_agent() {
 local pid n=0
 pid="$(loaded_pid)"
 launchctl bootout "${DOMAIN}/${LABEL}" || return 1
 while launchctl print "${DOMAIN}/${LABEL}" >/dev/null 2>&1 || { [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; }; do
  (( ++n <= 100 )) || { print -u2 "${LABEL} did not stop within 10 seconds."; return 1; }
  sleep 0.1
 done
}

# The launcher opens the UI through LaunchServices, so stopping the agent leaves the UI running.
# Stop exactly the UI this app recorded, and only while that PID still runs this app's executable.
stop_ui() {
 local pid n=0
 [[ -f "$UI_RECORD" ]] || return 0
 pid="$(plutil -extract process.pid raw "$UI_RECORD" 2>/dev/null)" || return 0
 [[ "$pid" == <-> && "$(ps -o comm= -p "$pid" 2>/dev/null)" == "$EXE" ]] || return 0
 kill -TERM "$pid" 2>/dev/null || return 0
 while kill -0 "$pid" 2>/dev/null; do
  (( ++n <= 100 )) || { kill -KILL "$pid" 2>/dev/null || true; break; }
  sleep 0.1
 done
}

if [[ "${1:-}" == --uninstall ]]; then
 if [[ -n "$(loaded_program)" ]]; then
  stop_agent || { print -u2 "Could not stop ${LABEL}; nothing was removed."; exit 1; }
 fi
 stop_ui
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
[[ -x "${NEW_APP}/Contents/MacOS/UsageTouchBar" && -x "${NEW_APP}/${LAUNCHER#${APP}/}" ]] \
 || { print -u2 'The new build is missing the app or its launcher; nothing was changed.'; exit 1; }
codesign --verify --deep --strict "$NEW_APP" || { print -u2 'The new build is not validly signed; nothing was changed.'; exit 1; }
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
		<string>${LAUNCHER}</string>
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
previous_program="$(loaded_program)"
[[ -z "$previous_program" ]] || was_loaded=1
if [[ -e "$APP" ]]; then cp -Rp "$APP" "${RECOVERY}/previous.app"; fi
if [[ -f "$PLIST" ]]; then cp -p "$PLIST" "${RECOVERY}/previous.plist"; fi
# Restarts a loaded agent that had no plist, with the program it was running (UI or launcher).
sed "s|<string>${LAUNCHER}</string>|<string>${previous_program:-$LAUNCHER}</string>|" "${STAGE}/agent.plist" > "${RECOVERY}/restart.plist"

previous_pid=''
swap() {
 previous_pid="$(loaded_pid)"
 if (( was_loaded )); then stop_agent || return 1; fi
 stop_ui
 rm -rf "$APP" || return 1
 mv "$NEW_APP" "$APP" || return 1
 cp "${STAGE}/agent.plist" "$PLIST" || return 1
 chmod 644 "$PLIST" || return 1
 launchctl bootstrap "$DOMAIN" "$PLIST" || return 1
}

restore() {
 local ok=1
 # The previous job may have left launchd but still be exiting; never replace files under it.
 if { [[ -n "$(loaded_program)" ]] && ! stop_agent; } || { [[ -n "$previous_pid" ]] && kill -0 "$previous_pid" 2>/dev/null; }; then
  print -u2 "Could not stop ${LABEL}; the previous install's files are kept in ${RECOVERY} (previous.app, previous.plist, restart.plist)."
  return
 fi
 stop_ui
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
print "Installed ${APP}. Its launcher starts at login and opens the Touch Bar strip when Claude, Codex or Grok work starts; Quit keeps it closed until new work or a manual open."
print "It reads usage through ${ROOT}/statusline/statusline.sh, so keep this folder where it is (or run ./install.sh again after moving it)."
