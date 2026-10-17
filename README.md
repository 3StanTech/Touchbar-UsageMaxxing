# Touchbar UsageMaxxing

A macOS menu-bar accessory that keeps Claude and Codex plan usage on the MacBook Pro Touch Bar: the 5-hour and weekly windows for both providers, side by side, always one glance away.

```
■ Claude ▮▮▯▯▯ 44% 2h 41m   ━━━━━━|━━━ 23%      ■ Codex ▮▮▯▯▯ 39% 3h 12m   ━━━━━━━━|━ 83% Wed 11:38am
```

## What it shows

- **5-hour window:** five thin segments (20% each), percent, and time until reset.
- **Weekly window:** a pill with a white **pace tick** marking how much of the week has passed. Fill past the tick means you are spending faster than the week.
- **Colors** come from the reader: green under 50%, yellow 50–79%, red 80% and over. At 100% the meter is replaced by `Limit` and the reset time.
- **Honest freshness:** a provider dims and shows `↻ 12m` when its data is stale, `Wait` when the usage endpoint is throttled, `Reader` when the reader's sign-in is unavailable. Cached values and their real ages are kept; one provider failing never dims the other.
- **Tap the strip** to refresh. The Control Strip button (a two-bar glyph of both weekly windows) brings the strip back.
- **Notifications** (optional): a banner at 90% of the 5-hour window or 98% of the weekly window, and a "monitoring delayed" banner when a provider near its limit has gone three minutes without fresh data.

The strip appears automatically while a Claude or Codex desktop app, or a Claude, Codex or Grok CLI, is running and steps aside when they close. Native Touch Bar popups (brightness, volume) are left alone for ten seconds before the strip reclaims the bar.

## Requirements

- A MacBook Pro with a Touch Bar, macOS 13 or later, Apple Silicon.
- Xcode Command Line Tools (`xcode-select --install`); they also provide the `python3` the reader runs on.
- Claude Code and/or Codex signed in on this Mac (see [Sign-in and privacy](#sign-in-and-privacy)).

## Install

```bash
git clone https://github.com/3StanTech/Touchbar-UsageMaxxing.git
cd Touchbar-UsageMaxxing
./install.sh
```

`install.sh` builds the app into `~/Applications/UsageTouchBar.app`, ad-hoc signs it, and registers a LaunchAgent (`local.agents.usagetouchbar`) so it starts at login and restarts if it exits. The app reads usage through `statusline/statusline.sh` in this folder, so keep the folder where it is; after moving it, run `./install.sh` again. `./install.sh --uninstall` removes the app and the agent.

Because the agent keeps the app alive, **Quit restarts it**; use **Hide Touch Bar overlay** from the `Usage` menu instead. To get banners, click the notifications item in the same menu; if notifications were declined earlier, it opens System Settings → Notifications.

Logs: `~/Library/Logs/UsageTouchBar/events.json` (last 200 events). State: `~/Library/Application Support/UsageTouchBar/`.

## Sign-in and privacy

The reader (`statusline/statusline.sh`) asks each provider's own usage endpoint for your plan usage and keeps the results in `statusline/cache/`. It needs no API keys of its own; it uses the sign-ins already on this Mac:

- **Claude:** Claude Code's sign-in (the `Claude Code-credentials` Keychain item, or `~/.claude/.credentials.json`), or the token of a Claude desktop app Code session that is running, read in memory and never stored. When the terminal sign-in has expired, the reader can renew it the way Claude Code does and save it back to the same Keychain item (off by default; see below); macOS may ask once to allow Keychain access.
- **Codex:** `~/.codex/auth.json` from the Codex CLI or app.
- **Grok** (only when the reader runs as a Grok CLI statusline): `$GROK_HOME/auth.json`, by default `~/.grok/auth.json`.

The Touch Bar's requests go only to `api.anthropic.com`, `platform.claude.com` (renewal) and `chatgpt.com`; used as a Grok CLI statusline, the reader also asks `cli-chat-proxy.grok.com` (billing credits) and `grok.com/rest/subscriptions` (plan details) with the Grok sign-in. Tokens are never printed or logged. Reset times are shown in the Mac's time zone.

### Claude sign-in renewal (opt-in)

By default the reader only reads your Claude sign-in. If the terminal sign-in has expired and no valid token is available, the Claude side shows `Reader` and the reader reports `sign_in_expired` until Claude Code refreshes it. To let the reader renew it instead, create the switch file:

```bash
mkdir -p ~/Library/Application\ Support/UsageTouchBar
touch ~/Library/Application\ Support/UsageTouchBar/renew-claude-signin
```

Delete the file to turn renewal off again. With it on, the reader uses Claude Code's public OAuth client ID and refresh token to request a new token, then writes the renewed sign-in back to the `Claude Code-credentials` Keychain item (`security add-generic-password -U`) under Claude Code's own refresh lock. Renewal rotates the refresh token, so before renewing the reader checks that the item, plus room for new tokens up to twice the size of the current ones, fits the 4 KB `security` standard-input limit. A very large sign-in (for example one carrying many MCP tokens) skips renewal (`store_too_large`) and the reader reports `sign_in_expired` until Claude Code renews it itself. An unusually large renewal response could still fail to save; if that happens, sign in to Claude Code again. Credentials are only ever passed to `security` on standard input, never as command-line arguments.

### Disclaimer

This is an unofficial project, not affiliated with or endorsed by Anthropic or OpenAI. It reads usage from undocumented endpoints that may change or stop working without notice. The optional Claude renewal mirrors the behavior of Claude Code 2.1.299 and, when enabled, rewrites that Keychain item; if Claude Code changes how it stores or refreshes sign-ins, the renewal may fail or need updating. Use it at your own risk.

## Terminal statusline (optional)

The same reader works as a statusline for Claude Code (and the Grok CLI). Under Claude Code, its own usage reports then keep the Touch Bar fresher. In `~/.claude/settings.json`:

```json
"statusLine": { "type": "command", "command": "/ABSOLUTE/PATH/TO/Touchbar-UsageMaxxing/statusline/statusline.sh" }
```

## Build only

```bash
./build-provider.sh --output "$PWD/build/UsageTouchBar.app"
```

The output path must be absolute and end in `.app`. The build records the reader's absolute path in the bundle (`--reader PATH` to use another copy), compiles `provider-ui/`, ad-hoc signs the bundle and verifies the signature.

## Layout

| Path | Role |
|---|---|
| `provider-ui/main.swift` | The app: Touch Bar strip, menu, refresh scheduling, cache watcher. |
| `provider-ui/UsageNotifications.swift` | Limit and monitoring-gap notifications with a persistent de-duplication ledger. |
| `statusline/statusline.sh` | The usage reader (Python 3): provider requests, back-off, cache, terminal statusline. |
| `install.sh`, `build-provider.sh` | Install/uninstall; the build. |
| `Info.plist`, `TouchBarPrivate.h` | Bundle metadata; private Touch Bar API declarations. |

## Private APIs

The system-modal strip and Control Strip button use undocumented AppKit and `DFRFoundation` calls (`presentSystemModalTouchBar:systemTrayItemIdentifier:`, `addSystemTrayItem:`, `DFRElementSetControlStripPresenceForIdentifier`). They are resolved at runtime and fail quietly if missing. The ✕ close box cannot be hidden for a background accessory app.

## License

MIT. See [LICENSE](LICENSE).
