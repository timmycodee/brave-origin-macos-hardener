#!/bin/bash
# Brave Origin macOS Hardener — TUI
# Applies Brave Origin-equivalent enterprise policies to /Library/Managed Preferences/<bundle-id>.plist
# Reversible, update-proof, no purchase bypass (never touches Local State).
# macOS stock bash 3.2 compatible. Zero dependencies.

VERSION="1.0.0"
MP_DIR="/Library/Managed Preferences"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_SUFFIX_TEMPLATE=".bak"
BACKUP_COUNT=5

# ---------------------------------------------------------------- colors
if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
    B="$(tput bold)"; R="$(tput setaf 1)"; G="$(tput setaf 2)"; Y="$(tput setaf 3)"; BL="$(tput setaf 4)"; C="$(tput setaf 6)"; W="$(tput setaf 7)"; X="$(tput sgr0)"
else
    B=""; R=""; G=""; Y=""; BL=""; C=""; W=""; X=""
fi
info()  { printf "%s[+]%s %s\n" "$G" "$X" "$1"; }
warn()  { printf "%s[!]%s %s\n" "$Y" "$X" "$1"; }
err()   { printf "%s[x]%s %s\n" "$R" "$X" "$1" >&2; }
die()   { err "$1"; exit 1; }
hdr()   { printf "\n%s%s%s\n" "$B$C" "$1" "$X"; }

# ---------------------------------------------------------------- policy catalog
# key|value|type|title
# type: bool | int
ALL_POLICIES='BraveRewardsDisabled|true|bool|Brave Rewards
BraveWalletDisabled|true|bool|Brave Wallet
BraveVPNDisabled|true|bool|Brave VPN
BraveAIChatEnabled|false|bool|Leo AI chat
BraveNewsDisabled|true|bool|Brave News
BraveTalkDisabled|true|bool|Brave Talk
BraveWaybackMachineEnabled|false|bool|Wayback Machine
BravePlaylistEnabled|false|bool|Playlist
BraveSpeedreaderEnabled|false|bool|Speedreader
EmailAliasesEnabled|false|bool|Email Aliases
PsstEnabled|false|bool|Psst privacy tuning
BraveP3AEnabled|false|bool|P3A analytics
BraveStatsPingEnabled|false|bool|Usage ping
BraveWebDiscoveryEnabled|false|bool|Web Discovery
BraveLocalAIEnabled|false|bool|On-device AI
TorDisabled|true|bool|Tor windows
HighEfficiencyModeEnabled|true|bool|Memory Saver
BatterySaverModeAvailability|1|int|Battery Saver
BackgroundModeEnabled|false|bool|Background mode (tray)
EnableMediaRouter|false|bool|Cast/mDNS scanning
DNSInterceptionChecksEnabled|false|bool|DNS hijack probes'

POLICY_TOTAL=$(printf '%s' "$ALL_POLICIES" | grep -c .)

preset_keys() {
    case "$1" in
        origin)      printf '%s\n' "$ALL_POLICIES" | sed -n '1,15p' | cut -d'|' -f1 ;;
        origin-tor)  printf '%s\n' "$ALL_POLICIES" | sed -n '1,16p' | cut -d| -f1 ;;
        full)        printf '%s\n' "$ALL_POLICIES" | cut -d'|' -f1 ;;
        *)           return 1 ;;
    esac
}

# ---------------------------------------------------------------- args
MODE="tui"; PRESET="full"; CHANNEL="stable"; BUNDLE_ID=""; AUTO_RESTART="ask"; EXIT_ON_FAIL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --verify) MODE="verify"; shift ;;
        --apply)  MODE="apply"; PRESET="${2:-full}"; shift 2 ;;
        --rollback) MODE="rollback"; shift ;;
        --measure) MODE="measure"; shift ;;
        --channel) CHANNEL="$2"; shift 2 ;;
        --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
        --restart) AUTO_RESTART="yes"; shift ;;
        --no-restart) AUTO_RESTART="no"; shift ;;
        --strict) EXIT_ON_FAIL=1; shift ;;
        -h|--help|help)
            sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
            echo "usage: $0 [--verify] [--apply origin|origin-tor|full] [--rollback] [--measure]"
            echo "       [--channel stable|beta|nightly|all] [--bundle-id com.brave.Browser]"
            echo "       [--restart|--no-restart] [--strict]"
            exit 0 ;;
        *) die "unknown flag: $1 (see --help)" ;;
    esac
done

# Non-tty password capture: if stdin is a pipe (not tty), grab one line NOW
# before anything else consumes it. sudo_run feeds it to sudo -S.
if [ ! -t 0 ]; then SUDO_PW=$(head -n 1 2>/dev/null); fi

# ---------------------------------------------------------------- helpers
sudo_run() {  # sudo_run <cmd> — tty: interactive prompt; pipe: uses SUDO_PW captured at startup
    if [ "$(id -u)" = 0 ]; then bash -c "$1"; return; fi
    if sudo -n true 2>/dev/null; then sudo bash -c "$1"; return; fi   # cached credential
    if [ -n "$SUDO_PW" ]; then
        printf '%s\n' "$SUDO_PW" | sudo -S -v 2>/dev/null || return 1
    elif [ -t 0 ]; then
        sudo -v -p "[sudo] password for %p: " || return 1
    else
        return 1   # no tty, no password, no cached credential
    fi
    sudo bash -c "$1"
}

detect_bundle_ids() {  # echo "<bundle-id>|<app-path>" per channel found
    # printf interprets \n; app names contain spaces so word-splitting is forbidden
    local paths=""
    if [ "$CHANNEL" = stable ] || [ "$CHANNEL" = all ]; then paths="$paths/Applications/Brave Browser.app\n"; fi
    if [ "$CHANNEL" = beta ]   || [ "$CHANNEL" = all ]; then paths="$paths/Applications/Brave Browser Beta.app\n"; fi
    if [ "$CHANNEL" = nightly ] || [ "$CHANNEL" = all ]; then paths="$paths/Applications/Brave Browser Nightly.app\n"; fi
    printf '%b' "$paths" | while IFS= read -r p; do
        [ -z "$p" ] && continue
        if [ -d "$p" ]; then
            local bid
            bid=$(defaults read "$p/Contents/Info.plist" CFBundleIdentifier 2>/dev/null)
            [ -n "$bid" ] && printf '%s|%s\n' "$bid" "$p"
        fi
    done
}

# pick one bundle id (or iterate all)
resolve_targets() {
    TARGETS=""
    if [ -n "$BUNDLE_ID" ]; then
        TARGETS="$BUNDLE_ID"
        return 0
    fi
    local found
    found=$(detect_bundle_ids)
    [ -z "$found" ] && { warn "no Brave install found (stable/beta/nightly). Pass --bundle-id to apply anyway."; return 1; }
    if [ "$(printf '%s\n' "$found" | grep -c .)" -gt 1 ] && [ "$CHANNEL" != all ]; then
        # multiple channels installed but one requested: pick matching name
        local want="Brave Browser"; [ "$CHANNEL" = beta ] && want="Brave Browser Beta"; [ "$CHANNEL" = nightly ] && want="Brave Browser Nightly"
        TARGETS=$(printf '%s\n' "$found" | awk -F'|' -v w="$want" '$2 ~ w {print $1}')
    else
        TARGETS=$(printf '%s\n' "$found" | cut -d'|' -f1)
    fi
    [ -n "$TARGETS" ] && return 0 || return 1
}

plist_get() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null; }

readback_ok() {  # readback_ok <plist> <key> <wantval> <type>
    local got
    got=$(plist_get "$1" "$2")
    [ "$got" = "$3" ]
}

apply_plist() {  # apply_plist <plist> <keysnewline> — sudo; atomic; merge; backup
    local plist="$1" keys="$2"
    local tmp; tmp=$(mktemp -t braveorigin)
    local had_existing=0
    if [ -f "$plist" ]; then
        cp "$plist" "$tmp"; had_existing=1
    else
        printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict/>\n</plist>\n' > "$tmp"
    fi
    local key vtype vwant
    printf '%s\n' "$keys" | while IFS= read -r key; do
        [ -z "$key" ] && continue
        vwant=$(printf '%s\n' "$ALL_POLICIES" | awk -F'|' -v k="$key" '$1==k{print $2}')
        vtype=$(printf '%s\n' "$ALL_POLICIES" | awk -F'|' -v k="$key" '$1==k{print $3}')
        if /usr/libexec/PlistBuddy -c "Set :$key $vwant" "$tmp" >/dev/null 2>&1; then :
        else
            /usr/libexec/PlistBuddy -c "Add :$key $vtype $vwant" "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; die "PlistBuddy failed on $key"; }
        fi
    done
    /usr/bin/plutil -lint "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; die "generated plist failed lint (bug — report it)"; }
    local backupcmd
    if [ "$had_existing" = 1 ]; then
        backupcmd="cp '$plist' '$plist$BACKUP_SUFFIX_TEMPLATE.$(date +%Y%m%d%H%M%S)'"
        # prune old backups — while-read because dir has a space (xargs would split it)
        backupcmd="$backupcmd; ls -1t '$plist.bak.'* 2>/dev/null | tail -n +$((BACKUP_COUNT+1)) | while IFS= read -r old; do rm -f \"\$old\"; done"
    fi
    local cmd="install -m 644 -o root -g wheel '$tmp' '$plist'; rm -f '$tmp'"
    [ -n "$backupcmd" ] && cmd="$backupcmd; $cmd"
    sudo_run "$cmd" || { rm -f "$tmp" 2>/dev/null; die "sudo install failed: $cmd"; }
    return 0
}

verify_plist() {  # verify_plist <plist> <keysnewline> -> prints OK/FAIL lines, returns failcount via global
    local plist="$1" keys="$2" fail=0 n=0 key vwant vtype got
    printf '%s\n' "$keys" | while IFS= read -r key; do :; done  # noop for scoping
    while IFS= read -r key; do
        [ -z "$key" ] && continue
        vwant=$(printf '%s\n' "$ALL_POLICIES" | awk -F'|' -v k="$key" '$1==k{print $2}')
        vtype=$(printf '%s\n' "$ALL_POLICIES" | awk -F'|' -v k="$key" '$1==k{print $3}')
        n=$((n+1))
        got=$(plist_get "$plist" "$key")
        if [ "$got" = "$vwant" ]; then
            printf "%s  OK   %s%s%s = %s\n" "$G" "$X" "$key" "" "$vwant"
        else
            printf "%s FAIL  %s = '%s' (want '%s')%s\n" "$R" "$key" "$got" "$vwant" "$X"
            fail=$((fail+1))
        fi
    done <<EOF
$keys
EOF
    VERIFY_N=$n
    return $fail
}

restart_brave() {
    local bid="$1" appname="Brave Browser"
    case "$bid" in
        *Beta*) appname="Brave Browser Beta" ;;
        *Nightly*) appname="Brave Browser Nightly" ;;
    esac
    if osascript -e "tell application \"$appname\" to quit" >/dev/null 2>&1; then
        sleep 2; open -a "$appname"; info "restarted $appname"
    else
        open -a "$appname" 2>/dev/null && info "launched $appname" || warn "could not launch $appname — policies apply on next manual start"
    fi
}

open_policy_page() {
    local bid="$1" appname="Brave Browser"
    case "$bid" in
        *Beta*) appname="Brave Browser Beta" ;;
        *Nightly*) appname="Brave Browser Nightly" ;;
    esac
    osascript -e "tell application \"$appname\" to make new window" >/dev/null 2>&1
    sleep 1
    osascript -e "tell application \"$appname\" to set URL of active tab of front window to \"brave://policy\"" >/dev/null 2>&1
}

measure_brave() {
    hdr "Brave process/RAM breakdown"
    if ! pgrep -x "Brave Browser" >/dev/null 2>&1 && ! pgrep -f "Brave Browser.app" >/dev/null 2>&1; then
        warn "Brave not running — start it for a live measure."
        return 0
    fi
    ps axo rss=,args= | grep "[B]rave Browser" | awk '{
        a=""; for(i=2;i<=NF;i++) a=a" "$i;
        if (a ~ /--type=gpu-process/) t="gpu";
        else if (a ~ /--extension-process/) t="extensions";
        else if (a ~ /--type=renderer/) t="renderers(tabs)";
        else if (a ~ /NetworkService/) t="network";
        else if (a ~ /--type=utility/) t="utility";
        else t="main";
        c[t]++; s[t]+=$1
    } END {
        for (k in c) printf "  %-16s %2d procs  %7.0f MB\n", k, c[k], s[k]/1024;
        for (k in s) tot+=s[k];
        printf "  %-16s %2d procs  %7.0f MB total\n", "TOTAL", 0, tot/1024;
    }'
    local tor=0
    tor=$(ps ax | grep -c "[T]orBrowser")
    printf "  Tor processes: %s\n" "$tor"
}

rollback_plist() {
    local plist="$1"
    if [ ! -e "$plist" ]; then err "no plist at $plist — nothing to roll back"; return 1; fi
    local newest
    newest=$(ls -1t "$plist.bak."* 2>/dev/null | head -1)
    if [ -n "$newest" ]; then
        info "restoring backup: $newest"
        sudo_run "cp '$newest' '$plist' && chown root:wheel '$plist' && chmod 644 '$plist'" || die "restore failed"
    else
        info "no backup found — deleting policy plist (back to fully stock Brave)"
        sudo_run "rm -f '$plist'" || die "delete failed"
    fi
}

# ---------------------------------------------------------------- TUI
pause_key() { printf "%s" "$Y[press Enter to continue]$X"; read -r _; }

tui_menu() {
    while :; do
        clear
        printf "%s%sBrave Origin macOS Hardener v%s%s — enterprise-policy debloat\n" "$B$C" "" "$VERSION" "$X"
        printf "plist: %s\n\n" "$MP_DIR/<bundle-id>.plist"
        printf "  %s1)%s  Apply preset   %s(full recommended)%s\n" "$B" "$X" "$W" "$X"
        printf "  %s2)%s  Custom toggle (all %s policies)%s\n" "$B" "$X" "$POLICY_TOTAL" "$X"
        printf "  %s3)%s  Verify current\n" "$B" "$X"
        printf "  %s4)%s  Measure Brave RAM\n" "$B" "$X"
        printf "  %s5)%s  Rollback (backup/stock)\n" "$B" "$X"
        printf "  %sq)%s  Quit\n" "$B" "$X"
        printf "\nchoice: "
        read -r choice
        case "$choice" in
            1) tui_apply ;;
            2) tui_custom ;;
            3) tui_verify ;;
            4) measure_brave; pause_key ;;
            5) tui_rollback ;;
            q|Q|*) exit 0 ;;
        esac
    done
}

tui_resolve_target() {
    resolve_targets || { pause_key; return 1; }
    if [ "$(printf '%s\n' "$TARGETS" | grep -c .)" -gt 1 ]; then
        printf "\nmultiple Brave installs found:\n"
        local i=1 sel
        local all="$TARGETS"
        TARGETS=""
        while IFS= read -r bid; do
            printf "  %s%d)%s %s\n" "$B" "$i" "$X" "$bid"
            i=$((i+1))
        done <<EOF
$all
EOF
        printf "apply to (1-%s, or 'all') a: " "$((i-1))"
        read -r sel
        if [ "$sel" = "a" ] || [ "$sel" = all ]; then TARGETS="$all";
        else
            TARGETS=$(printf '%s\n' "$all" | sed -n "${sel}p")
            [ -n "$TARGETS" ] || { err "bad selection"; pause_key; return 1; }
        fi
    fi
    return 0
}

tui_pick_preset() {
    printf "\npresets:\n"
    printf "  %s1)%s origin      (15 — feature debloat, Tor kept)\n" "$B" "$X"
    printf "  %s2)%s origin-tor  (16 — + Tor off)\n" "$B" "$X"
    printf "  %s3)%s full        (21 — + Memory Saver etc. %srecommended%s)\n" "$B" "$X" "$G" "$X"
    printf "choice [3]: "
    read -r sel
    case "${sel:-3}" in
        1) echo origin ;;
        2) echo origin-tor ;;
        *) echo full ;;
    esac
}

tui_apply() {
    hdr "Apply"
    tui_resolve_target || return 0
    local preset; preset=$(tui_pick_preset)
    local keys; keys=$(preset_keys "$preset") || { err "bad preset"; pause_key; return 0; }
    local nkeys; nkeys=$(printf '%s\n' "$keys" | grep -c .)
    info "applying %s policies (%s) to:" "$nkeys" "$preset"
    printf '%s\n' "$TARGETS"
    local bid plist fails=0
    while IFS= read -r bid; do
        plist="$MP_DIR/$bid.plist"
        apply_plist "$plist" "$keys" && info "written: $plist" || { fails=1; continue; }
    done <<EOF
$TARGETS
EOF
    [ "$fails" = 1 ] && { err "one or more plists failed"; pause_key; return 0; }
    info "verifying..."
    while IFS= read -r bid; do
        verify_plist "$MP_DIR/$bid.plist" "$keys"
    done <<EOF
$TARGETS
EOF
    if [ "$AUTO_RESTART" != no ]; then
        printf "\nrestart Brave now? [Y/n] "
        local r; read -r r
        case "$r" in n|N) : ;; *)
            while IFS= read -r bid; do restart_brave "$bid"; done <<EOF
$TARGETS
EOF
            info "opening brave://policy for visual proof (expect: Source=Platform, Level=Mandatory, Status=OK)"
            while IFS= read -r bid; do open_policy_page "$bid"; done <<EOF
$TARGETS
EOF
            ;;
        esac
    fi
    pause_key
}

tui_custom() {
    hdr "Custom toggle"
    tui_resolve_target || return 0
    # selection state as space-separated key list
    local sel_keys=""
    # preselect current plist state if exists
    local bid plist; bid=$(printf '%s\n' "$TARGETS" | head -1); plist="$MP_DIR/$bid.plist"
    if [ -f "$plist" ]; then
        sel_keys=$(printf '%s\n' "$ALL_POLICIES" | while IFS='|' read -r k v t d; do
            got=$(plist_get "$plist" "$k"); [ "$got" = "$v" ] && printf '%s\n' "$k"
        done | tr '\n' ' ')
    fi
    while :; do
        clear
        printf "%sCustom policy selection%s — space toggles, ENTER saves, 'q' aborts\n" "$B$C" "$X"
        printf "(x = will be enforced)\n\n"
        local i=1
        printf '%s\n' "$ALL_POLICIES" | while IFS='|' read -r k v t d; do
            case " $sel_keys " in *" $k "*) mark="${G}x${X}";; *) mark="${W}.${X}";; esac
            printf "  %s2%s) [%s] %-40s = %s\n" "$B" "$i" "$mark" "$k = $v" "$d"
            i=$((i+1))
        done
        printf "\nnumber (or ENTER save / q): "
        read -r num
        case "$num" in
            q|Q) return 0 ;;
            "") break ;;
            *[!0-9]*) warn "numbers only" ;;
            *)
                [ "$num" -lt 1 ] || [ "$num" -gt "$POLICY_TOTAL" ] && { warn "out of range"; continue; }
                key=$(printf '%s\n' "$ALL_POLICIES" | sed -n "${num}p" | cut -d'|' -f1)
                case " $sel_keys " in *" $key "*) sel_keys=$(printf '%s' " $sel_keys " | sed "s| $key | |" | xargs) ;;
                    *) sel_keys="$sel_keys $key" ;;
                esac
                ;;
        esac
    done
    if [ -z "$sel_keys" ]; then warn "nothing selected — aborting"; pause_key; return 0; fi
    local keys; keys=$(printf '%s\n' "$sel_keys" | tr ' ' '\n' | grep -c . | xargs -I{} sh -c 'printf "%s\n" "$sel_keys" | tr " " "\n" | sed "/^$/d"')
    # sel_keys -> newline list
    keys=$(printf '%s' "$sel_keys" | tr ' ' '\n' | sed '/^$/d')
    while IFS= read -r bid; do
        apply_plist "$MP_DIR/$bid.plist" "$keys" && info "written: $MP_DIR/$bid.plist"
    done <<EOF
$TARGETS
EOF
    pause_key
}

tui_verify() {
    hdr "Verify"
    resolve_targets || { pause_key; return 0; }
    while IFS= read -r bid; do
        printf "\n%s%s%s\n" "$B" "$MP_DIR/$bid.plist" "$X"
        verify_plist "$MP_DIR/$bid.plist" "$(printf '%s\n' "$ALL_POLICIES" | cut -d'|' -f1)" && : 
    done <<EOF
$TARGETS
EOF
    pause_key
}

tui_rollback() {
    hdr "Rollback"
    resolve_targets || { pause_key; return 0; }
    while IFS= read -r bid; do
        rollback_plist "$MP_DIR/$bid.plist"
    done <<EOF
$TARGETS
EOF
    pause_key
}

# ---------------------------------------------------------------- entry
banner() {
    printf "%s%sBrave Origin macOS Hardener%s v%s — apply/verify/rollback enterprise policies\n\n" "$B$C" "$X" "$VERSION"
}

case "$MODE" in
    verify)
        banner
        resolve_targets || die "no Brave target"
        fails=0
        while IFS= read -r bid; do
            printf "%s%s%s\n" "$B" "$MP_DIR/$bid.plist" "$X"
            verify_plist "$MP_DIR/$bid.plist" "$(printf '%s\n' "$ALL_POLICIES" | cut -d'|' -f1)" || fails=$((fails+1))
        done <<EOF
$TARGETS
EOF
        if [ "$fails" -gt 0 ]; then
            err "$fails plist(s) have drift — re-run --apply or check above"
            [ "$EXIT_ON_FAIL" = 1 ] && exit 2
            exit 2
        fi
        info "all policies OK on every target"
        exit 0
        ;;
    apply)
        banner
        keys=$(preset_keys "$PRESET") || die "unknown preset: $PRESET (origin|origin-tor|full)"
        [ -z "$keys" ] && die "preset resolved to zero policies (bug)"
        resolve_targets || die "no Brave target (install Brave or pass --bundle-id)"
        while IFS= read -r bid; do
            plist="$MP_DIR/$bid.plist"
            apply_plist "$plist" "$keys"
            printf "%s  written %s%s\n" "$G" "$plist" "$X"
            verify_plist "$plist" "$keys" || true
        done <<EOF
$TARGETS
EOF
        if [ "$AUTO_RESTART" != no ]; then
            while IFS= read -r bid; do restart_brave "$bid"; done <<EOF
$TARGETS
EOF
        fi
        info "done. open brave://policy — expect Source=Platform, Level=Mandatory, Status=OK"
        ;;
    rollback)
        banner
        resolve_targets || die "no Brave target"
        while IFS= read -r bid; do rollback_plist "$MP_DIR/$bid.plist"; done <<EOF
$TARGETS
EOF
        ;;
    measure)
        banner
        measure_brave
        ;;
    tui)
        # non-interactive sanity: if not a tty, behave like --verify
        if [ ! -t 0 ] || [ ! -t 1 ]; then
            MODE=verify
            banner
            resolve_targets || die "no Brave target (non-tty mode: auto-verify)"
            fails=0
            while IFS= read -r bid; do
                printf "%s%s%s\n" "$B" "$MP_DIR/$bid.plist" "$X"
                verify_plist "$MP_DIR/$bid.plist" "$(printf '%s\n' "$ALL_POLICIES" | cut -d'|' -f1)" || fails=1
            done <<EOF
$TARGETS
EOF
            exit $([ "$fails" -gt 0 ] && echo 2 || echo 0)
        fi
        tui_menu
        ;;
esac
exit 0
