#!/bin/bash
# probe.sh: run 13 checks on a macOS machine (install, configure, launch and observe apps) and
# record the results.
#
# Usage: probe.sh <output-dir>
#
# Writes <output-dir>/results.json, <output-dir>/logs/NN-name.log and
# <output-dir>/screenshots/. A failed check never stops the script; a check
# whose prerequisite failed is recorded as "skipped". The script exits 0 when
# every check has a recorded result, and 2 when it cannot write its results.
#
# Needs only stock macOS tools: bash 3.2, curl, osascript, plutil, ditto,
# codesign, screencapture, sqlite3. No fixed sleeps: every wait polls for its
# condition with an overall deadline.

# shellcheck disable=SC2329  # functions are invoked indirectly through run_check/step/poll
set -u

OUT_ARG="${1:-}"
if [ -z "$OUT_ARG" ]; then
  echo "usage: $0 <output-dir>" >&2
  exit 2
fi
mkdir -p "$OUT_ARG/logs" "$OUT_ARG/screenshots" || exit 2
OUT="$(cd "$OUT_ARG" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export PATH="$HOME/.local/bin:$PATH"

FEED_URL="https://downloads.claude.ai/releases/darwin/universal/RELEASES.json"
APP_REQ='anchor apple generic and identifier "com.anthropic.claudefordesktop" and certificate leaf[subject.OU] = "Q6L2SF6YDW"'
DESKTOP_CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
MCP_NAME="probe-stdio"

# ---------------------------------------------------------------- helpers

now_ms() {
  perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000' 2>/dev/null || echo $(($(date +%s) * 1000))
}

# with_deadline <seconds> <command...>: run the command, poll for its exit,
# kill it at the deadline. Returns the command's status, or 124 on timeout.
with_deadline() {
  local secs="$1" pid end
  shift
  "$@" </dev/null &
  pid=$!
  end=$(($(date +%s) + secs))
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$(date +%s)" -ge "$end" ]; then
      echo "DEADLINE: killing after ${secs}s: $*" >&2
      kill "$pid" 2>/dev/null
      pkill -P "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 0.2 # poll interval while the command runs, not a readiness wait
  done
  wait "$pid"
}

# poll <seconds> <command...>: run the command until it succeeds. Status 99
# from the command means "stop polling, definitive failure".
poll() {
  local secs="$1" rc end attempt=0
  shift
  end=$(($(date +%s) + secs))
  while :; do
    attempt=$((attempt + 1))
    "$@"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      echo "poll: condition met on attempt $attempt"
      return 0
    fi
    if [ "$rc" -eq 99 ]; then
      echo "poll: definitive failure on attempt $attempt"
      return 99
    fi
    if [ "$(date +%s)" -ge "$end" ]; then
      echo "poll: DEADLINE after ${secs}s, $attempt attempts"
      return 124
    fi
    sleep 1 # poll interval between attempts, bounded by the deadline above
  done
}

FIRSTRC=0
note_rc() {
  if [ "$1" -ne 0 ] && [ "$FIRSTRC" -eq 0 ]; then FIRSTRC="$1"; fi
}

# step <command...>: log and run; a nonzero status fails the check.
step() {
  local rc
  printf '+ %s\n' "$*"
  "$@"
  rc=$?
  printf '[exit %s]\n' "$rc"
  note_rc "$rc"
  return "$rc"
}

# dstep <seconds> <command...>: like step, with a deadline.
dstep() {
  local secs="$1" rc
  shift
  printf '+ (deadline %ss) %s\n' "$secs" "$*"
  with_deadline "$secs" "$@"
  rc=$?
  printf '[exit %s]\n' "$rc"
  note_rc "$rc"
  return "$rc"
}

# info <command...>: log and run; the status does not fail the check.
info() {
  local rc
  printf '+ (info) %s\n' "$*"
  with_deadline 60 "$@"
  rc=$?
  printf '[exit %s, informational]\n' "$rc"
  return 0
}

fail_with() {
  echo "FAIL: $1"
  note_rc "${2:-1}"
}

# ----------------------------------------------------------------- checks

check_1_machine() {
  step sysctl -n hw.model
  info sysctl -n kern.hv_support
  info sysctl -n machdep.cpu.brand_string
  step sw_vers
  step uname -m
}

check_2_user() {
  step whoami
  step id
  step sudo -n true
}

check_3_desktop_session() {
  local me console
  me="$(id -un)"
  info launchctl print "gui/$(id -u)"
  console="$(stat -f %Su /dev/console)"
  echo "console owner: $console; job user: $me"
  if [ "$console" != "$me" ]; then
    fail_with "console is owned by '$console', not '$me'"
  fi
}

check_4_install_claude_code() {
  if dstep 120 curl -fsSL --max-time 100 -o "$WORK/claude-install.sh" https://claude.ai/install.sh; then
    if ! dstep 900 bash "$WORK/claude-install.sh"; then
      echo "--- diagnostics after failed install"
      info curl -sS -i --max-time 30 https://downloads.claude.ai/claude-code-releases/latest
      info curl -sS -4 -i --max-time 30 https://downloads.claude.ai/claude-code-releases/latest
      info scutil --proxy
    fi
  fi
}

lsregister_dump_claude() {
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -dump 2>/dev/null | grep -i -m5 'claude.app'
}

check_5_verify_claude_code() {
  local bin
  step command -v claude || return
  bin="$(command -v claude)"
  dstep 60 claude --version
  info ls -l "$bin"
  info ls -la "$HOME/.local/share/claude"
  info ls -la "$HOME/.claude"
}

check_6_install_claude_desktop() {
  local feed="$WORK/RELEASES.json" cur url host i v zip="$WORK/claude.zip" ex="$WORK/claude-extract"
  dstep 60 curl --proto '=https' -fsSL --max-time 50 -o "$feed" "$FEED_URL" || return
  cur="$(plutil -extract currentRelease raw -o - "$feed")" || { fail_with "no currentRelease in feed"; return; }
  echo "feed currentRelease: $cur"
  printf '%s\n' "$cur" >"$WORK/feed_version"
  url=""
  i=0
  while [ "$i" -lt 100 ]; do
    v="$(plutil -extract "releases.$i.version" raw -o - "$feed" 2>/dev/null)" || break
    if [ "$v" = "$cur" ]; then
      url="$(plutil -extract "releases.$i.updateTo.url" raw -o - "$feed")"
      break
    fi
    i=$((i + 1))
  done
  [ -n "$url" ] || { fail_with "no release entry for $cur"; return; }
  echo "download url: $url"
  case "$url" in
    https://*) ;;
    *) fail_with "url is not https"; return ;;
  esac
  host="${url#https://}"
  host="${host%%/*}"
  case "$host" in
    *[@:]*) fail_with "url host '$host' has userinfo or port"; return ;;
    claude.ai | *.claude.ai) ;;
    *) fail_with "url host '$host' is not on claude.ai"; return ;;
  esac
  dstep 900 curl --proto '=https' --max-redirs 0 -fsS -o "$zip" "$url" || return
  mkdir -p "$ex"
  dstep 300 ditto -x -k "$zip" "$ex" || return
  info ls -la "$ex"
  [ -d "$ex/Claude.app" ] || { fail_with "Claude.app not in archive"; return; }
  step codesign --verify --deep --strict "-R=$APP_REQ" "$ex/Claude.app" || return
  dstep 300 ditto "$ex/Claude.app" /Applications/Claude.app
}

check_7_verify_claude_desktop() {
  local feed_v="" app_v
  [ -f "$WORK/feed_version" ] && feed_v="$(cat "$WORK/feed_version")"
  # The feed version is read again here, so this check stands alone.
  if [ -z "$feed_v" ]; then
    feed_v="$(curl --proto '=https' -fsSL --max-time 30 "$FEED_URL" 2>/dev/null | plutil -extract currentRelease raw -o - - 2>/dev/null)"
  fi
  step test -d /Applications/Claude.app || return
  app_v="$(plutil -extract CFBundleShortVersionString raw -o - /Applications/Claude.app/Contents/Info.plist)" \
    || { fail_with "cannot read CFBundleShortVersionString"; return; }
  echo "installed version: $app_v"
  echo "feed currentRelease: ${feed_v:-unknown}"
  if [ "$app_v" = "$feed_v" ]; then echo "versions match"; else echo "versions differ"; fi
}

check_8_desktop_mcp_entry() {
  local expected="$WORK/expected_desktop_config.json" got
  mkdir -p "$(dirname "$DESKTOP_CONFIG")" || { fail_with "cannot create config dir"; return; }
  cat >"$expected" <<'JSON'
{
  "mcpServers": {
    "probe-stdio": {
      "command": "/bin/echo",
      "args": ["probe"]
    }
  }
}
JSON
  cp "$expected" "$DESKTOP_CONFIG" || { fail_with "cannot write config"; return; }
  step plutil -extract mcpServers json -o - "$DESKTOP_CONFIG"
  step cmp "$expected" "$DESKTOP_CONFIG"
  got="$(plutil -extract mcpServers.probe-stdio.command raw -o - "$DESKTOP_CONFIG")"
  echo "read back command: $got"
  [ "$got" = "/bin/echo" ] || fail_with "command did not read back"
  got="$(plutil -extract mcpServers.probe-stdio.args.0 raw -o - "$DESKTOP_CONFIG")"
  echo "read back args[0]: $got"
  [ "$got" = "probe" ] || fail_with "args did not read back"
}

check_9_claude_code_mcp_entry() {
  command -v claude >/dev/null 2>&1 || { fail_with "claude not on PATH"; return; }
  dstep 120 claude mcp add "$MCP_NAME" -- /bin/echo probe
  dstep 180 claude mcp list >"$WORK/mcp_list.txt" 2>&1
  cat "$WORK/mcp_list.txt"
  if grep -q "$MCP_NAME" "$WORK/mcp_list.txt"; then
    echo "server listed"
  else
    fail_with "server '$MCP_NAME' not listed"
  fi
}

claude_running() { pgrep -x Claude; }

check_10_launch() {
  # LaunchServices may need time to register a freshly copied app: poll the name lookup.
  if ! poll 30 open -a Claude; then
    echo "NOTE: 'open -a Claude' by name did not succeed; trying the explicit path"
    info lsregister_dump_claude
    step open /Applications/Claude.app || return
  fi
  poll 90 claude_running || fail_with "Claude process did not appear within 90s" 124
}

windows_ready() {
  local out
  out="$(osascript -e 'tell application "System Events" to count windows of process "Claude"' 2>&1)"
  echo "osascript: $out"
  case "$out" in
    *"not allowed"* | *"(-1743)"* | *"(-25211)"* | *"assistive access"*) return 99 ;;
  esac
  case "$out" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ "$out" -ge 1 ]
}

check_11_find_window() {
  poll 90 windows_ready || fail_with "no Claude window found" 124
}

check_12_screenshot() {
  local png="$OUT/screenshots/12-screen.png" jxa="$WORK/nonblank.js"
  cat >"$jxa" <<'JS'
ObjC.import('AppKit');
function run(argv) {
  var data = $.NSData.dataWithContentsOfFile(argv[0]);
  if (!data) { return 'ERROR: cannot read file'; }
  var rep = $.NSBitmapImageRep.imageRepWithData(data);
  if (!rep) { return 'ERROR: not an image'; }
  var w = rep.pixelsWide, h = rep.pixelsHigh, seen = {}, n = 0, x, y, c, key;
  var space = $.NSColorSpace.genericRGBColorSpace;
  for (x = 0; x < 48; x++) {
    for (y = 0; y < 48; y++) {
      c = rep.colorAtXY(Math.floor((x + 0.5) * w / 48), Math.floor((y + 0.5) * h / 48));
      c = c.colorUsingColorSpace(space);
      key = Math.round(c.redComponent * 255) + ',' + Math.round(c.greenComponent * 255) + ',' + Math.round(c.blueComponent * 255);
      if (!seen[key]) { seen[key] = 1; n++; }
    }
  }
  return 'size=' + w + 'x' + h + ' distinct_colors=' + n;
}
JS
  dstep 60 screencapture -x "$png" || return
  info ls -l "$png"
  info sips -g pixelWidth -g pixelHeight "$png"
  local res
  res="$(osascript -l JavaScript "$jxa" "$png" 2>&1)"
  echo "analysis: $res"
  case "$res" in
    *distinct_colors=*) ;;
    *) fail_with "could not analyse screenshot"; return ;;
  esac
  case "$res" in
    *distinct_colors=1) fail_with "screenshot is a single flat colour (blank)" ;;
  esac
}

check_13_ui_permission() {
  local db
  dstep 30 osascript -e 'tell application "System Events" to get name of every process whose background only is false'
  for db in "$HOME/Library/Application Support/com.apple.TCC/TCC.db" "/Library/Application Support/com.apple.TCC/TCC.db"; do
    echo "TCC database: $db"
    info sqlite3 -readonly "$db" "select service, client, auth_value, auth_reason from access;"
  done
}

# ----------------------------------------------------------------- runner

IDX=0
NAMES=()
RESULTS=()
ENTRIES=()

# run_check <num> <slug> <function> [dependency-num...]
run_check() {
  local n="$1" slug="$2" fn="$3" dep t0 t1 rc result log
  shift 3
  IDX=$((IDX + 1))
  log="logs/$(printf '%02d' "$n")-$slug.log"
  NAMES[n]="$slug"
  for dep in "$@"; do
    if [ "${RESULTS[dep]:-}" != "pass" ]; then
      printf 'SKIPPED: check %s (%s) did not pass\n' "$dep" "${NAMES[dep]:-?}" >"$OUT/$log"
      RESULTS[n]="skipped"
      ENTRIES[IDX]="{\"num\":$n,\"name\":\"$slug\",\"result\":\"skipped\",\"exit_code\":null,\"duration_ms\":0,\"log\":\"$log\"}"
      echo "check $n $slug: skipped"
      return
    fi
  done
  t0="$(now_ms)"
  (
    FIRSTRC=0
    "$fn"
    note_rc $?
    exit "$FIRSTRC"
  ) >"$OUT/$log" 2>&1
  rc=$?
  t1="$(now_ms)"
  if [ "$rc" -eq 0 ]; then result="pass"; else result="fail"; fi
  RESULTS[n]="$result"
  ENTRIES[IDX]="{\"num\":$n,\"name\":\"$slug\",\"result\":\"$result\",\"exit_code\":$rc,\"duration_ms\":$((t1 - t0)),\"log\":\"$log\"}"
  echo "check $n $slug: $result (exit $rc, $((t1 - t0)) ms)"
}

STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "probe start $STARTED, output $OUT"

run_check 1 machine check_1_machine
run_check 2 user check_2_user
run_check 3 desktop-session check_3_desktop_session
run_check 4 claude-code-install check_4_install_claude_code
run_check 5 claude-code-verify check_5_verify_claude_code 4
run_check 6 claude-desktop-install check_6_install_claude_desktop
run_check 7 claude-desktop-verify check_7_verify_claude_desktop 6
run_check 8 desktop-mcp-entry check_8_desktop_mcp_entry
run_check 9 claude-code-mcp-entry check_9_claude_code_mcp_entry 4
run_check 10 launch check_10_launch 6
run_check 11 find-window check_11_find_window 10
run_check 12 screenshot check_12_screenshot
run_check 13 ui-permission check_13_ui_permission

FINISHED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
LABEL="${PROBE_LABEL:-local}"
{
  printf '{"label":"%s","user":"%s","started":"%s","finished":"%s","checks":[' "$LABEL" "$(id -un)" "$STARTED" "$FINISHED"
  i=1
  while [ "$i" -le "$IDX" ]; do
    [ "$i" -gt 1 ] && printf ','
    printf '%s' "${ENTRIES[i]}"
    i=$((i + 1))
  done
  printf ']}\n'
} >"$OUT/results.json"

if ! plutil -extract checks json -o /dev/null "$OUT/results.json" >&2; then
  echo "results.json is not valid JSON" >&2
  exit 2
fi
echo "probe finished $FINISHED"
exit 0
