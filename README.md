# Brave Origin macOS Hardener

Apply **Brave Origin-equivalent debloat** on any macOS via enterprise managed
preferences. Terminal UI, zero dependencies, fully reversible.

```bash
./hardener.sh                # interactive TUI menu
./hardener.sh --verify       # exit 0 = all 21 policies OK, exit 2 = drift
./hardener.sh --apply full   # non-interactive: origin | origin-tor | full
./hardener.sh --rollback     # restore backup or remove plist (stock Brave)
./hardener.sh --measure      # Brave process/RAM breakdown
```

Flags: `--channel stable|beta|nightly|all` · `--bundle-id <id>` (Brave not
installed) · `--restart` / `--no-restart` · `--strict` (CI).

## Why this method (not an unlocker flag)

- Brave's own Origin **upgrade-mode** works by Brave flipping enterprise
  policies internally ("Brave manages group policies internally" — Brave Help
  Center). This script writes the same policies directly.
- **Never touches `Local State` / `brave.origin.purchase_validated`** — no
  purchase bypass, no risk to profile data, no forged payload.
- Enterprise policy = supported management API (`brave://policy` shows
  **Source: Platform, Level: Mandatory, Status: OK**) → survives Brave
  updates, cannot be patched away, and overrides even Origin's own panel.
- Hard-off: features disabled by `*Disabled=true` policies cannot be re-enabled
  from Settings.

## Presets

| Preset | Policies | What |
|---|---|---|
| `origin` | 15 | Feature debloat only (Tor kept) |
| `origin-tor` | 16 | + Tor windows disabled |
| `full` | 21 | + Memory Saver, Battery Saver, no background mode, no Cast scanning, no DNS probes — **recommended** |

All 21 keys verified against brave-core (`brave_policies.gni` + policy YAMLs)
and live-tested at `brave://policy` on Brave 1.9x:

Rewards, Wallet, VPN, AIChat(Leo), News, Talk, Wayback, Playlist, Speedreader,
EmailAliases, Psst, P3A, StatsPing, WebDiscovery, LocalAI off; TorDisabled;
HighEfficiencyModeEnabled (Memory Saver); BatterySaverModeAvailability=1;
BackgroundModeEnabled=false; EnableMediaRouter=false;
DNSInterceptionChecksEnabled=false.

## Safety properties

- **Merge, never clobber** — other policies already in the plist (e.g. set by
  an org) are preserved.
- **Backup + prune** — `.bak.<timestamp>` next to the plist (max 5); rollback
  restores the newest.
- **Atomic install** — plist built in a temp file, `plutil -lint` checked, then
  installed `root:wheel 644`.
- **Reversible** — `./hardener.sh --rollback`, or
  `sudo rm "/Library/Managed Preferences/com.brave.Browser.plist"`.
- macOS **stock bash 3.2** compatible; no brew/node/network needed.
- Multi-channel: auto-detects stable/beta/nightly bundle IDs from Info.plist.

## After a Brave update

Policies persist (the file is root-owned; the updater only touches
`/Applications` and the user profile). Chromium/Brave may add/rename/retire
policy names over time — unknown keys are silently ignored; worst case a
retired policy's feature returns to default. Audit ritual after a major
version bump: `./hardener.sh --verify` or eyeball `brave://policy`.

## Pitfalls encoded in the script

1. `sudo defaults write '/path/file.plist' key -bool v` is a trap — under
   sudo, `defaults` resolves the argument as a *domain* and writes to root's
   `~/Library/Preferences/<domain>.plist`, not the target path. All file
   writes use `/usr/libexec/PlistBuddy` with explicit paths.
2. macOS ships bash 3.2 — no associative arrays; `;;` inside `case` within a
   one-line `$( )` is a syntax error (use awk).
3. `xargs rm` splits paths containing spaces (`/Library/Managed Preferences`)
   — prune uses `while IFS= read -r`.
4. Non-interactive use: `printf '%s\n' "$pw" | ./hardener.sh --apply full`
   (password read once from stdin at startup).

Not affiliated with Brave Software. "Brave" is a trademark of Brave Software, Inc.
MIT — do whatever.
