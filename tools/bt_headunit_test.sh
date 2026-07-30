#!/usr/bin/env bash
#
# Reproduce "head unit presses PLAY / connects while the phone is idle and
# Musly is off" without a car, over wireless debugging.
#
# Lane A — head-unit PLAY, fully simulated. A head unit's AVRCP PLAY becomes a
#          MediaSessionManager.dispatchMediaKeyEvent inside the BT stack, which
#          is exactly what `cmd media_session dispatch play` issues. Runs
#          against any build, including the release APK.
#
# Lane B — A2DP connect. Needs a debug build (tools hook in
#          src/debug/DebugBluetoothReceiver.kt); drives the resume-on-connect
#          path with no Bluetooth hardware at all.
#
# Usage:
#   tools/bt_headunit_test.sh                 # all scenarios
#   tools/bt_headunit_test.sh A3 A4           # only these
#   tools/bt_headunit_test.sh --serial 192.168.1.5:5555 --doze A2
#
# Results (verdict + full logcat per scenario) land in tools/bt-test-results/.

set -uo pipefail

PKG="com.devid.musly"
ACTIVITY="$PKG/.MainActivity"
ADB_BIN="${ADB:-adb}"
SERIAL=""
DISPATCH="cmd"      # cmd | media | key
DOZE=0
MANUAL_SWIPE=0
WAIT_SECS=15
RESULT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bt-test-results"
RUN_DIR="$RESULT_ROOT/$(date +%Y%m%d-%H%M%S)"

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'

SCENARIOS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --serial) SERIAL="$2"; shift 2 ;;
    --dispatch) DISPATCH="$2"; shift 2 ;;
    --wait) WAIT_SECS="$2"; shift 2 ;;
    --doze) DOZE=1; shift ;;
    --manual-swipe) MANUAL_SWIPE=1; shift ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    A1|A2|A3|A4|B1|B2) SCENARIOS+=("$1"); shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ ${#SCENARIOS[@]} -eq 0 ]] && SCENARIOS=(A1 A2 A3 A4 B1 B2)

# `command` bypasses function lookup — without it this recurses into itself,
# since ADB_BIN defaults to the same name as this wrapper.
adb() {
  if [[ -n "$SERIAL" ]]; then command "$ADB_BIN" -s "$SERIAL" "$@"
  else command "$ADB_BIN" "$@"; fi
}
sh_() { adb shell "$@" 2>/dev/null; }

# ── device state helpers ────────────────────────────────────────────────────

app_pid()      { sh_ pidof "$PKG" | tr -d '\r' | awk '{print $1}'; }
app_uid()      { sh_ dumpsys package "$PKG" | grep -m1 -o 'userId=[0-9]*' | cut -d= -f2 | tr -d '\r'; }
activity_up()  { sh_ dumpsys activity activities | grep -q "$PKG/.MainActivity"; }
service_up()   { sh_ dumpsys activity services "$PKG" | grep -q "MusicService"; }

# PlaybackState of Musly's media session. Android 14+ prints the named form
# "state=PLAYING(3)"; older builds print a bare "state=3". Handle both.
session_state() {
  sh_ dumpsys media_session \
    | sed -n 's/.*state=PlaybackState {state=\([A-Z_]*\)(\([0-9]*\)).*/\1/p;
               s/.*state=PlaybackState {state=\([0-9]\+\).*/\1/p' \
    | head -1
}

playing_state() { [[ "$(session_state)" == "PLAYING" || "$(session_state)" == "3" ]]; }

# Ground truth: is the audio framework actually rendering for our uid?
audio_started() {
  local uid; uid="$(app_uid)"
  [[ -z "$uid" ]] && return 1
  sh_ dumpsys audio | grep -E "u/pid:$uid/" | grep -q "state:started"
}

playing_now() {
  audio_started && return 0
  playing_state && return 0
  return 1
}

wait_for_play() {
  local deadline=$((SECONDS + WAIT_SECS))
  while (( SECONDS < deadline )); do
    playing_now && { echo $((WAIT_SECS - (deadline - SECONDS))); return 0; }
    sleep 1
  done
  return 1
}

# ── setup / teardown ────────────────────────────────────────────────────────

quiesce() {
  sh_ cmd media_session dispatch pause >/dev/null
  sleep 1
  (( DOZE )) && sh_ dumpsys deviceidle unforce >/dev/null
  sh_ input keyevent KEYCODE_WAKEUP >/dev/null
}

screen_off() {
  sh_ input keyevent KEYCODE_SLEEP >/dev/null
  sleep 1
  if (( DOZE )); then
    sh_ dumpsys battery unplug >/dev/null
    sh_ dumpsys deviceidle force-idle >/dev/null
    sleep 2
  fi
}

launch_app() {
  sh_ am start -n "$ACTIVITY" >/dev/null
  # Give PlayerProvider time to construct, restore the queue and wire services.
  sleep 6
}

# Reach "process gone, package NOT stopped" — the state a head unit actually
# meets after Musly has been closed for a while.
#
# `am kill` alone is not enough: MusicService keeps the process at a proc state
# the killer will not touch, and swiping from Recents does not help either
# because stopWithTask="false" keeps the service (and therefore the process)
# alive. Crashing the app, dismissing its dialog, then stopping the service and
# killing what is left does reach it. Deliberately NOT `am force-stop`, which
# additionally sets the package's stopped flag — that cancels the media button
# PendingIntent, and no app can recover from it.
detach_engine() {
  if (( MANUAL_SWIPE )); then
    read -rp "  → Swipe Musly out of Recents on the phone, then press Enter: " _
  else
    sh_ am crash "$PKG" >/dev/null; sleep 5
    sh_ input keyevent KEYCODE_BACK >/dev/null; sleep 2
    sh_ input keyevent KEYCODE_HOME >/dev/null; sleep 2
    sh_ am stopservice "$PKG/.MusicService" >/dev/null; sleep 2
    sh_ am kill "$PKG" >/dev/null
  fi
  local deadline=$((SECONDS + 20))
  while (( SECONDS < deadline )); do
    [[ -z "$(app_pid)" ]] && return 0
    sleep 1
  done
  return 1
}

dispatch_play() {
  case "$DISPATCH" in
    cmd)   sh_ cmd media_session dispatch play ;;
    media) sh_ media dispatch play ;;
    key)   sh_ input keyevent 126 ;;
  esac
}

# ── evidence ────────────────────────────────────────────────────────────────

start_logcat() {
  adb logcat -c 2>/dev/null
  adb logcat -v time > "$1" 2>/dev/null &
  LOGCAT_PID=$!
  sleep 1
}

stop_logcat() {
  [[ -n "${LOGCAT_PID:-}" ]] && kill "$LOGCAT_PID" 2>/dev/null
  wait "$LOGCAT_PID" 2>/dev/null
  LOGCAT_PID=""
}

# Which link of the chain was reached, and where it stopped.
diagnose() {
  local log="$1"
  grep -q "MusicService onPlay\|MediaSessionCallback" "$log" && echo "    · MediaSession onPlay reached"
  grep -q "AndroidAuto command received: play" "$log"        && echo "    · command delivered to Flutter"
  grep -q "DEBUG_BT result=" "$log" && \
    echo "    · $(grep -m1 -o 'DEBUG_BT result=.*' "$log")"
  grep -q "Bluetooth A2DP audio active" "$log" && \
    echo "    · $(grep -m1 -o 'Bluetooth A2DP audio active.*' "$log")"
  grep -q "BT resume-on-connect failed" "$log" && \
    echo "    ${RED}· resume-on-connect threw${RST}"
  grep -qi "Background activity .*blocked\|Abort background activity starts\|BAL Abort" "$log" && \
    echo "    ${RED}· BACKGROUND ACTIVITY LAUNCH BLOCKED — MusicService.kt:869 cannot start MainActivity${RST}"
  grep -q "ForegroundServiceStartNotAllowedException" "$log" && \
    echo "    ${RED}· ForegroundServiceStartNotAllowedException — MusicService.onCreate startForeground refused${RST}"
  grep -q "Could not find any Service that handles" "$log" && \
    echo "    ${RED}· MediaButtonReceiver found no handler service${RST}"
}

PASSES=(); FAILS=()

run_scenario() {
  local id="$1" desc="$2"
  local log="$RUN_DIR/$id.logcat"
  echo
  echo "${DIM}────────────────────────────────────────────────────────${RST}"
  echo "  $id  $desc"

  quiesce
  launch_app

  case "$id" in
    A1) : ;;                                            # stays foreground
    A2) sh_ input keyevent KEYCODE_HOME >/dev/null; sleep 2; screen_off ;;
    A3) sh_ input keyevent KEYCODE_HOME >/dev/null; sleep 2; screen_off
        detach_engine || echo "    ${YEL}warn: could not reach 'engine detached, service alive'${RST}" ;;
    A4) sh_ input keyevent KEYCODE_HOME >/dev/null; sleep 2; screen_off
        sh_ am force-stop "$PKG" >/dev/null; sleep 2 ;;
    B1) sh_ input keyevent KEYCODE_HOME >/dev/null; sleep 2; screen_off ;;
    B2) sh_ input keyevent KEYCODE_HOME >/dev/null; sleep 2; screen_off
        detach_engine || echo "    ${YEL}warn: could not reach 'engine detached, service alive'${RST}" ;;
  esac

  echo "    ${DIM}state: pid=$(app_pid) activity=$(activity_up && echo up || echo down)" \
       "service=$(service_up && echo up || echo down) session=$(session_state)${RST}"

  start_logcat "$log"

  case "$id" in
    A*) dispatch_play ;;
    # Explicit component: an implicit broadcast would not start a manifest
    # receiver on Android 8+. Deliberately no FLAG_INCLUDE_STOPPED_PACKAGES —
    # a real ACL_CONNECTED does not carry it either.
    B*) sh_ am broadcast -n "$PKG/.DebugBluetoothReceiver" \
            -a com.devid.musly.DEBUG_BT_STATUS >/dev/null
        sh_ am broadcast -n "$PKG/.DebugBluetoothReceiver" \
            -a com.devid.musly.DEBUG_BT_CONNECT >/dev/null ;;
  esac

  local elapsed
  if elapsed="$(wait_for_play)"; then
    echo "  ${GRN}PASS${RST}  playing after ~${elapsed}s  (session state=$(session_state), audio=$(audio_started && echo started || echo silent))"
    PASSES+=("$id")
  else
    echo "  ${RED}FAIL${RST}  no playback within ${WAIT_SECS}s  (session state=$(session_state))"
    FAILS+=("$id")
  fi

  sleep 1
  stop_logcat
  diagnose "$log"
  echo "    ${DIM}log: ${log/#$PWD\//}${RST}"
}

# ── preflight ───────────────────────────────────────────────────────────────

mkdir -p "$RUN_DIR"

if ! adb get-state >/dev/null 2>&1; then
  echo "${RED}No device.${RST}  Connect first:"
  echo "  adb pair <phone-ip>:<pair-port>     # Settings → Developer options → Wireless debugging"
  echo "  adb connect <phone-ip>:<port>"
  exit 1
fi

if ! sh_ pm list packages | grep -q "package:$PKG"; then
  echo "${RED}$PKG is not installed on the device.${RST}"
  exit 1
fi

DEBUGGABLE=0
sh_ run-as "$PKG" true >/dev/null 2>&1 && DEBUGGABLE=1

echo "device:      $(sh_ getprop ro.product.model | tr -d '\r') / Android $(sh_ getprop ro.build.version.release | tr -d '\r')"
echo "package:     $PKG ($(sh_ dumpsys package "$PKG" | grep -m1 versionName | tr -d ' \r'))"
echo "build:       $([[ $DEBUGGABLE == 1 ]] && echo debuggable || echo "release (Lane B unavailable)")"
echo "dispatch:    $DISPATCH"
echo "results:     ${RUN_DIR/#$PWD\//}"

# Resume-on-connect and cold PLAY are both no-ops without a restored queue.
if (( DEBUGGABLE )); then
  if sh_ run-as "$PKG" cat shared_prefs/FlutterSharedPreferences.xml 2>/dev/null \
       | grep -q "flutter.persistent_queue"; then
    echo "queue:       persisted queue present ${GRN}✓${RST}"
  else
    echo "queue:       ${YEL}no persisted queue — play a song once in the app first,${RST}"
    echo "             ${YEL}otherwise every scenario fails for the wrong reason${RST}"
  fi
else
  echo "queue:       ${DIM}unverifiable on a release build — make sure a song has played once${RST}"
fi

for id in "${SCENARIOS[@]}"; do
  case "$id" in
    A1) run_scenario A1 "app in foreground            → head unit PLAY   [baseline]" ;;
    A2) run_scenario A2 "app backgrounded, screen off → head unit PLAY   [warm path]" ;;
    A3) run_scenario A3 "engine detached, svc alive   → head unit PLAY   [the reported bug]" ;;
    A4) run_scenario A4 "process force-stopped        → head unit PLAY   [cold start]" ;;
    B1) if (( DEBUGGABLE )); then
          run_scenario B1 "app backgrounded, screen off → A2DP connect     [resume-on-connect]"
        else echo; echo "  ${YEL}SKIP B1${RST} — needs a debug build"; fi ;;
    B2) if (( DEBUGGABLE )); then
          run_scenario B2 "engine detached, svc alive   → A2DP connect     [expect NO_HELPER]"
        else echo; echo "  ${YEL}SKIP B2${RST} — needs a debug build"; fi ;;
  esac
done

quiesce

echo
echo "${DIM}────────────────────────────────────────────────────────${RST}"
echo "  passed: ${PASSES[*]:-none}"
echo "  failed: ${FAILS[*]:-none}"
echo
echo "  All six are things the app should do. A2 passing while A3 fails"
echo "  pins the bug on the background-activity-launch at MusicService.kt:869."
echo "  B1 passing while B2 reports NO_HELPER pins the Bluetooth receiver's"
echo "  lifetime to the Flutter engine (BluetoothAvrcpPlugin.kt:47)."
