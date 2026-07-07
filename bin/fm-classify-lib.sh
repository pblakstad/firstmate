#!/usr/bin/env bash
# Shared wake classifier: the common source of truth for captain-relevant status
# tests and, for the always-on watcher, the provably-working predicate that makes
# no-verb signal and stale-pane wakes safe to absorb.
# Sourced by BOTH the always-on watcher
# (bin/fm-watch.sh) and the away-mode daemon (bin/fm-supervise-daemon.sh) so the
# overlapping triage policy lives in one place instead of two copies that can
# drift apart.
#
# Most functions are pure, side-effect-free reads of status files: each takes
# what it needs as arguments and touches no globals beyond the optional
# FM_CAPTAIN_RE override. Consumers layer their own dedup/marker state on top (the
# daemon keeps its escalation-digest seen-markers; the watcher keeps its .seen-*
# signatures).
#
# The one exception is the "provably working" predicate (crew_is_provably_working
# and its signal-path wrapper). It is NOT a pure status-file read: it reuses
# bin/fm-crew-state.sh, which may make a bounded no-mistakes call, to decide
# whether a crew that just stopped its turn or went stale shows positive evidence
# it is still working. Callers run it ONLY on no-verb signal handling and first
# sighting of a stale hash, never on every wake, so the per-wake triage stays
# cheap.
#
# Auto-nudge watchdog knobs:
#   FM_MAX_AUTO_NUDGES          consecutive opencode nudges before giving up
#                               and surfacing for inspection (default 3)
#   FM_AUTO_NUDGE_INTERVAL_SECS minimum seconds between nudges for the same
#                               unchanged task-progress signature (default 60)
#   FM_AUTO_NUDGE_MESSAGE       generic continuation steer sent by fm-send
#   FM_SEND_BIN                 fm-send.sh path override for tests

# Directory of this library, used to locate the sibling fm-crew-state.sh reader.
# Resolved at source time from BASH_SOURCE so it works whether sourced by a
# bin/ script (which sets its own SCRIPT_DIR) or directly by a test.
_FM_CLASSIFY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_CLASSIFY_LIB_DIR="."

# The crew current-state reader used for the "provably working" decision.
# Overridable so tests can stub the run-step/pane verdict without a real worktree
# or no-mistakes install; absent, it points at the real sibling script.
FM_CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$_FM_CLASSIFY_LIB_DIR/fm-crew-state.sh}"
FM_SEND_BIN="${FM_SEND_BIN:-$_FM_CLASSIFY_LIB_DIR/fm-send.sh}"

# Captain-relevant status verbs. A status line carrying any of these is work
# firstmate must see. Lines without these verbs are no-verb signals: the watcher
# absorbs them only with positive provably-working evidence, while the daemon uses
# its away-mode classification. FM_CAPTAIN_RE overrides the whole set when a home
# needs a custom verb vocabulary; absent, this default applies.
FM_CLASSIFY_CAPTAIN_RE_DEFAULT='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'

_classify_stat_sig() {
  if [ "$(uname)" = Darwin ]; then
    stat -f '%z:%Fm' "$1" 2>/dev/null
  else
    stat -c '%s:%Y' "$1" 2>/dev/null
  fi
}

# Return the last non-blank line of a status file (empty if missing/blank).
last_status_line() {
  local f=$1
  [ -e "$f" ] || return 0
  grep -v '^[[:space:]]*$' "$f" 2>/dev/null | tail -1
}

# 0 if the given (last) status line matches a captain-relevant verb.
status_is_captain_relevant() {
  local line=$1
  [ -n "$line" ] || return 1
  printf '%s' "$line" | grep -qiE "${FM_CAPTAIN_RE:-$FM_CLASSIFY_CAPTAIN_RE_DEFAULT}"
}

# task id from a recorded window target, falling back to the tmux-shaped
# "<session>:fm-<id>" form when no metadata state is available.
window_to_task() {
  local w=$1 state=${2:-${STATE:-${FM_STATE_OVERRIDE:-}}} meta mw mt t
  if [ -n "$state" ]; then
    for meta in "$state"/*.meta; do
      [ -e "$meta" ] || continue
      mw=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      mt=$(grep '^terminal=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      [ "$mw" = "$w" ] || [ "$mt" = "$w" ] || continue
      t=$(basename "$meta")
      t=${t%.meta}
      printf '%s' "$t"
      return 0
    done
  fi
  t="${w##*:}"; t="${t#fm-}"; printf '%s' "$t"
}

# 0 (actionable) if ANY status file listed in a "signal:" wake carries a
# captain-relevant last line; 1 otherwise. Pass the space-separated file list that
# follows the "signal:" prefix. Non-.status arguments (e.g. .turn-ended markers,
# which never carry a verb) are skipped. A 1 here is NOT "benign" on its own: a
# no-verb signal (a bare turn-end, a working: note) is only benign when the crew is
# also provably working (signal_crew_provably_working below); otherwise it surfaces.
signal_reason_is_actionable() {  # <file> ...
  local f last
  for f in "$@"; do
    [ -e "$f" ] || continue
    case "$f" in *.status) ;; *) continue ;; esac
    last=$(last_status_line "$f")
    [ -n "$last" ] || continue
    status_is_captain_relevant "$last" && return 0
  done
  return 1
}

# 0 if crew <id> shows POSITIVE evidence it is still working; 1 otherwise. This is
# the "provably working" predicate at the heart of absorb-only-when-provably-working:
# a no-verb turn-end or stale wake is absorbed ONLY when this returns 0, and
# SURFACED otherwise (the crew may be done, waiting on a decision, or wedged).
# For stale panes, this verdict is checked before trusting the status log so a
# pre-validation captain-relevant line does not override an active run.
#
# It reuses bin/fm-crew-state.sh rather than duplicating its run-step logic, and
# treats the crew as provably working in exactly two cases, both read straight from
# that helper's one canonical line ("state: <s> · source: <src> · <detail>"):
#   (a) state working from source run-step - the crew's no-mistakes run for its
#       branch is in an actively-running step (running/fixing/ci), NOT terminal,
#       parked, passed, or failed; OR
#   (b) state working from source pane     - the pane shows the harness busy
#       signature.
# Everything else - a terminal/parked/failed run, an idle pane that fell back to a
# stale "working:" status-log line (source status-log), a torn-down or unknown
# crew, or an unreadable verdict - is NOT provably working, so the wake surfaces.
# NOT a pure read: fm-crew-state.sh may make a bounded no-mistakes call, so this
# runs only on no-verb signal and first-sighting stale paths. FM_CREW_STATE_BIN
# lets tests stub the verdict.
crew_is_provably_working() {  # <id>
  local id=$1 line state src
  [ -n "$id" ] || return 1
  line=$("$FM_CREW_STATE_BIN" "$id" 2>/dev/null) || true
  case "$line" in state:*) ;; *) return 1 ;; esac
  state=${line#state: }; state=${state%% *}
  [ "$state" = working ] || return 1
  src=${line#*source: }; src=${src%% *}
  case "$src" in
    run-step|pane) return 0 ;;
    *)             return 1 ;;
  esac
}

_auto_nudge_key() { printf '%s' "$1" | tr ':/.' '___'; }

_auto_nudge_meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

_auto_nudge_num() {  # <value> <default>
  case "$1" in
    ''|*[!0-9]*) printf '%s' "$2" ;;
    *)           printf '%s' "$1" ;;
  esac
}

auto_nudge_progress_for_task() {  # <task> <state> <extra-progress-token>
  local task=$1 state=$2 extra=${3:-} status_sig
  status_sig=$(_classify_stat_sig "$state/$task.status" 2>/dev/null || true)
  printf 'status=%s extra=%s' "$status_sig" "$extra"
}

auto_nudge_progress_for_stale_window() {  # <window> <state>
  local win=$1 state=$2 key pane_sig task
  key=$(printf '%s' "$win" | tr ':/.' '___')
  pane_sig=$(cat "$state/.hash-$key" 2>/dev/null || true)
  task=$(window_to_task "$win" "$state")
  auto_nudge_progress_for_task "$task" "$state" "pane=$pane_sig"
}

auto_nudge_task_decision() {  # <task> <state> <progress-signature>
  local task=$1 state=$2 progress_sig=$3 meta harness kind last line crew_state src key
  local count_file sig_file at_file escalated_file previous_sig count max interval now last_at target msg send_out
  [ -n "$task" ] || { printf 'none|auto-nudge skipped: no task'; return 0; }
  meta="$state/$task.meta"
  [ -f "$meta" ] || { printf 'none|auto-nudge skipped for %s: missing metadata' "$task"; return 0; }
  harness=$(_auto_nudge_meta_value "$meta" harness)
  kind=$(_auto_nudge_meta_value "$meta" kind)
  [ -n "$kind" ] || kind=ship
  [ "$kind" = secondmate ] && { printf 'none|auto-nudge skipped for %s: secondmate' "$task"; return 0; }
  [ "$harness" = opencode ] || { printf 'none|auto-nudge skipped for %s: harness=%s' "$task" "${harness:-unknown}"; return 0; }

  last=$(last_status_line "$state/$task.status")
  if [ -n "$last" ] && status_is_captain_relevant "$last"; then
    printf 'none|auto-nudge skipped for %s: terminal status' "$task"
    return 0
  fi

  line=$("$FM_CREW_STATE_BIN" "$task" 2>/dev/null) || true
  case "$line" in state:*) ;; *) line="state: unknown · source: none · unreadable crew state" ;; esac
  crew_state=${line#state: }; crew_state=${crew_state%% *}
  src=${line#*source: }; src=${src%% *}
  if [ "$crew_state" = working ]; then
    case "$src" in
      run-step|pane)
        printf 'safe|auto-nudge skipped for %s: provably working' "$task"
        return 0
        ;;
    esac
  fi
  case "$crew_state" in
    parked|done|blocked|failed)
      printf 'none|auto-nudge skipped for %s: current state %s' "$task" "$crew_state"
      return 0
      ;;
  esac

  key=$(_auto_nudge_key "$task")
  count_file="$state/.auto-nudges-$key"
  sig_file="$state/.auto-nudge-progress-$key"
  at_file="$state/.auto-nudge-at-$key"
  escalated_file="$state/.auto-nudge-escalated-$key"
  previous_sig=$(cat "$sig_file" 2>/dev/null || true)
  if [ "$previous_sig" != "$progress_sig" ]; then
    printf '%s' "$progress_sig" > "$sig_file"
    rm -f "$count_file" "$at_file" "$escalated_file" 2>/dev/null || true
  fi
  if [ "$(cat "$escalated_file" 2>/dev/null || true)" = "$progress_sig" ]; then
    printf 'self|auto-nudge already escalated for %s at this progress signature' "$task"
    return 0
  fi

  max=$(_auto_nudge_num "${FM_MAX_AUTO_NUDGES:-}" 3)
  interval=$(_auto_nudge_num "${FM_AUTO_NUDGE_INTERVAL_SECS:-}" 60)
  count=$(cat "$count_file" 2>/dev/null || echo 0)
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  if [ "$count" -ge "$max" ]; then
    printf '%s' "$progress_sig" > "$escalated_file"
    printf 'escalate|auto-nudge give-up for %s: %s consecutive nudges with no progress, demand-inspection' "$task" "$count"
    return 0
  fi

  now=$(date +%s)
  last_at=$(cat "$at_file" 2>/dev/null || echo 0)
  case "$last_at" in ''|*[!0-9]*) last_at=0 ;; esac
  if [ "$count" -gt 0 ] && [ "$interval" -gt 0 ] && [ $((now - last_at)) -lt "$interval" ]; then
    printf 'self|auto-nudge waiting for %s: last nudge %ss ago' "$task" "$((now - last_at))"
    return 0
  fi

  target="fm-$task"
  msg=${FM_AUTO_NUDGE_MESSAGE:-"continue - do not yield your turn until the task is committed and the PR is open, or you hit a real blocker"}
  if ! send_out=$("$FM_SEND_BIN" "$target" "$msg" 2>&1); then
    printf 'escalate|auto-nudge send failed for %s: %s' "$task" "$send_out"
    return 0
  fi
  count=$((count + 1))
  printf '%s\n' "$count" > "$count_file"
  printf '%s\n' "$now" > "$at_file"
  printf '%s' "$progress_sig" > "$sig_file"
  rm -f "$escalated_file" 2>/dev/null || true
  printf 'self|auto-nudged %s (%s/%s)' "$task" "$count" "$max"
}

auto_nudge_signal_decision() {  # <state> <file> ...
  local state=$1 f base task seen="" decision action detail any_self=0
  shift || true
  for f in "$@"; do
    base=${f##*/}
    case "$base" in
      *.status)     task=${base%.status} ;;
      *.turn-ended) task=${base%.turn-ended} ;;
      *)            continue ;;
    esac
    [ -n "$task" ] || continue
    case " $seen " in *" $task "*) continue ;; esac
    seen="$seen $task"
    decision=$(auto_nudge_task_decision "$task" "$state" "$(auto_nudge_progress_for_task "$task" "$state" signal)")
    action=${decision%%|*}
    detail=${decision#*|}
    case "$action" in
      self) any_self=1 ;;
      safe) ;;
      escalate) printf 'escalate|%s' "$detail"; return 0 ;;
      *) printf 'none|%s' "$detail"; return 0 ;;
    esac
  done
  [ -n "$seen" ] || { printf 'none|auto-nudge skipped: no signal task'; return 0; }
  [ "$any_self" = 1 ] && { printf 'self|auto-nudge handled signal for:%s' "$seen"; return 0; }
  printf 'safe|auto-nudge skipped: all signal crews are provably working'
}

auto_nudge_stale_decision() {  # <window> <state>
  local win=$1 state=$2 task
  task=$(window_to_task "$win" "$state")
  auto_nudge_task_decision "$task" "$state" "$(auto_nudge_progress_for_stale_window "$win" "$state")"
}

# 0 (benign/absorb) if EVERY task referenced by a no-verb "signal:" wake is provably
# working; 1 (actionable/surface) if any is not, or no task can be resolved. Pass the
# same space-separated file list as signal_reason_is_actionable. Files are mapped to
# task ids by stripping the .status / .turn-ended suffix; a no-verb wake with nothing
# provably working must surface, so an empty/unresolvable list returns 1.
signal_crew_provably_working() {  # <file> ...
  local f base task seen=""
  for f in "$@"; do
    base=${f##*/}
    case "$base" in
      *.status)     task=${base%.status} ;;
      *.turn-ended) task=${base%.turn-ended} ;;
      *)            continue ;;
    esac
    [ -n "$task" ] || continue
    case " $seen " in *" $task "*) continue ;; esac
    seen="$seen $task"
    crew_is_provably_working "$task" || return 1
  done
  [ -n "$seen" ] || return 1
  return 0
}

# 0 (terminal/actionable) if a stale window's last status line is
# captain-relevant; 1 otherwise, including the no-status case. A 1 only means
# "non-terminal"; the always-on watcher then applies crew_is_provably_working,
# while the away-mode daemon applies its persistence recheck.
stale_is_terminal() {  # <window> <state>
  local win=$1 state=$2 last
  last=$(last_status_line "$state/$(window_to_task "$win" "$state").status")
  [ -n "$last" ] && status_is_captain_relevant "$last"
}

# Print "<file>\t<task>\t<last-line>" for every state/*.status whose last line is
# captain-relevant. This is the cheap fleet-scan both supervisors run as a
# catch-all backstop for a captain-relevant status the per-wake path might miss.
# No dedup is applied here: each consumer dedupes against its own seen-state (the
# daemon against .subsuper-seen-status-*, the watcher against .seen-* signatures).
scan_captain_relevant_statuses() {  # <state>
  local state=$1 f last task
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    last=$(last_status_line "$f")
    status_is_captain_relevant "$last" || continue
    task=$(basename "$f"); task="${task%.status}"
    printf '%s\t%s\t%s\n' "$f" "$task" "$last"
  done
  return 0
}
