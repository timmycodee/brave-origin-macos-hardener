---
name: brave-origin-macos-hardener
description: "Apply, verify, or roll back Brave Origin-equivalent debloat policies on macOS via /Library/Managed Preferences (safe, reversible, update-proof, no purchase bypass). Use for Brave debloat, minimalist hardening, or Memory Saver setup on any Mac."
---

# Brave Origin macOS Hardener

Apply **Brave Origin-equivalent debloat** on any macOS via enterprise managed preferences. Terminal UI, zero dependencies, fully reversible.

## Why this method (not the unlocker flag)

- Origin upgrade-mode itself works by Brave flipping enterprise policies internally (help center: "Brave manages group policies internally to disable features"). This script writes the same policies directly.
- **Never touches `Local State` / `brave.origin.purchase_validated`** — no purchase bypass, no risk to profile data, no payload forgery.
- Enterprise policy = supported management API (Source: Platform, Level: Mandatory at `brave://policy`) → survives Brave updates, cannot be patched away, and overrides even Origin's own panel.
- Admin policies beat user settings: `*Disabled=true` features are hard-off and cannot be re-enabled from Settings.

## Quick start

```bash
cd <skill-dir>
./hardener.sh                # interactive TUI menu
./hardener.sh --verify       # CI-friendly: exit 0 = all OK, exit 2 = drift/missing
./hardener.sh --apply full   # non-interactive: origin|origin-tor|full
./hardener.sh --rollback     # restore backup or delete plist
./hardener.sh --measure      # Brave process/RAM breakdown
```

Flags: `--channel stable|beta|nightly|all`, `--bundle-id <id>` (app not installed), `--restart` / `--no-restart`.

## Presets

| Preset | Policies | What |
|---|---|---|
| `origin` | 15 | Feature debloat only (Tor kept, stock performance) |
| `origin-tor` | 16 | + Tor disabled |
| `full` | 21 | + Memory Saver, Battery Saver, no background mode, no Cast scan, no DNS probes — **recommended** |
| custom | any | Toggle each of the 21 |

The 21 policies (all verified in brave-core `brave_policies.gni` + policy YAMLs, and live-tested at `brave://policy` on Brave 1.9x):

Rewards, Wallet, VPN, AIChat(Leo), News, Talk, Wayback, Playlist, Speedreader, EmailAliases, Psst, P3A, StatsPing, WebDiscovery, LocalAI off; TorDisabled; HighEfficiencyModeEnabled (Memory Saver); BatterySaverModeAvailability=1; BackgroundModeEnabled=false; EnableMediaRouter=false; DNSInterceptionChecksEnabled=false.

## Verify

1. `./hardener.sh --verify` — reads back every key from the plist, prints `N/21 OK`.
2. Visual: open `brave://policy` — every row must show **Source: Platform, Level: Mandatory, Status: OK**. Script's apply+restart flow opens this page automatically.
3. Memory: `./hardener.sh --measure`.

## Rollback

- Restore most recent backup: `.bak.<timestamp>` files sit next to the plist.
- Or delete `/Library/Managed Preferences/com.brave.Browser.plist` entirely → stock Brave. Restart required.

## Porting to another Mac

Copy the whole skill folder → run `./hardener.sh`. Requires: macOS, admin password (sudo), Brave installed (or pass `--bundle-id`). No brew, no node, no network. Bundle IDs are auto-detected from each app's `Info.plist` (stable/beta/nightly).

## Pitfalls encoded in the script (do not "fix" them away)

1. **`sudo defaults write '/path/file.plist' key -bool v` is a trap** — under sudo, `defaults` resolves the argument as a *domain* and writes to root's `~/Library/Preferences/<domain>.plist`, NOT the target path. Silent failure, verified 2026-10-25. All file writes use `/usr/bin/libexec/PlistBuddy` with explicit paths (Set first, Add fallback).
2. **macOS ships bash 3.2** — no associative arrays, no `readarray`. Script uses string lists + `read` loops.
3. **Atomic install**: plist built in `mktemp` temp file → `plutil -lint` → backup old → `cp` into place → `root:wheel 644` (world-readable so unprivileged verify works).
4. **Merge, never clobber**: if an org already set other policies in the plist, they are preserved (script only touches its own 21 keys).
5. File must be named exactly `<bundle-id>.plist` inside `/Library/Managed Preferences/` (MDM location Brave/Chromium reads at startup).

## After a Brave update

Policies persist (root-owned file, updater only touches `/Applications` + profile). Chromium/Brave may add/rename/retire policies over time — unknown keys are silently ignored (nothing breaks), worst case a retired policy's feature returns to default. Audit ritual: run `--verify` or eyeball `brave://policy` after major version bumps.

## Evidence (source machine, 2026-10-25)

- 21/21 policies live at `brave://policy`: Source Platform, Mandatory, OK (AX-scraped, not assumed).
- RAM: utility process 205→71 MB (MediaRouter off); Tor process count 0 (never spawns without a Tor window); Memory Saver active for idle-tab reclaim. Total ~1.6 GB with 3 crypto extensions + tabs — floor is set by extensions/tabs, not Brave features.
- Root cause research in vault: `20-research/brave-origin-unlock-mechanism-2026-10-25.md`.
