#!/usr/bin/env bash
# Durable conference recorder with a live local transcript.
#
#   ./record-talk.sh [name]                 start, or resume the same name
#   ./record-talk.sh --transcribe <name>    finish transcribing, no recording
#
# While recording, a terminal shows one live line: time recorded, mic level,
# transcription progress, restarts and the latest words. It turns red with NO
# AUDIO if ffmpeg stops receiving audio, or SILENT if the mic hears nothing.
#
# Press Ctrl-C once to stop; it then finishes the remaining transcription.
# If any segment is left untranscribed it says how many, gives the --transcribe
# command to recover them, and exits non-zero.
#
# Audio is written as short FLAC segments, so a crash costs seconds, not the
# recording. ffmpeg restarts automatically if it dies or stalls. Each segment
# is transcribed on its own and the finished results are never redone, so
# rerunning after any failure picks up where it left off.
#
# One run per name at a time: a second one is refused while the first is alive.
# After a kill -9, rerunning stops the leftover ffmpeg and takes over.
#
# Overrides: MIC, MODEL, SEGMENT_SECONDS, THREADS, BASE_DIR, STALL_SECONDS,
# ALLOW_SILENT_MIC=1 (record even though the mic check hears only silence)
# TEST_AUDIO=<file> loops that file instead of the mic, to test without one.
set -u

BASE_DIR="${BASE_DIR:-$(cd "$(dirname "$0")" && pwd)}"
MIC="${MIC:-MacBook Pro Microphone}"
MODEL="${MODEL:-small.en}"
SEGMENT_SECONDS="${SEGMENT_SECONDS:-300}"
THREADS="${THREADS:-4}"
STALL_SECONDS="${STALL_SECONDS:-30}"
MIN_SEGMENT_BYTES=4096   # smaller is a fragment from an instant restart
NO_AUDIO_ALERT_SECONDS=6
SILENT_DB=-70            # a live mic in a quiet room stays well above this
SILENT_ALERT_SECONDS=20
MODEL_DIR="$HOME/.cache/whisper"
MODEL_FILE="$MODEL_DIR/ggml-$MODEL.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$MODEL.bin"

usage() { echo "usage: $0 [name] | $0 --transcribe <name> | $0 --help"; }

MODE=record
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --transcribe)
    MODE=transcribe
    shift
    [ -n "${1:-}" ] || { usage >&2; exit 2; } ;;
esac
case "${1:-}" in -*) usage >&2; exit 2 ;; esac
[ $# -le 1 ] || { usage >&2; exit 2; }
NAME="${1:-talk-$(date +%Y%m%d-%H%M)}"
DIR="$BASE_DIR/$NAME"
AUDIO="$DIR/audio"
TEXT="$DIR/text"
LOG="$DIR/recorder.log"
TRANSCRIPT="$DIR/transcript.txt"
STOP_FILE="$DIR/.stop-transcribing"
PROGRESS="$DIR/.ffmpeg-progress"
LOCK="$DIR/.lock"

if [ "$MODE" = transcribe ]; then
  SEGMENTS=("$AUDIO"/seg-*.flac)
  [ -e "${SEGMENTS[0]}" ] || { echo "ERROR: no recording at $AUDIO" >&2; exit 1; }
fi

log() {
  [ -t 1 ] && printf '\r\033[K'   # clear the status line, which redraws itself
  echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"
}

ensure_tools() {
  local tool
  for tool in ffmpeg whisper-cli curl perl lsof; do
    command -v "$tool" >/dev/null || { log "ERROR: $tool not found"; exit 1; }
  done
}

try_lock() {
  exec 9>>"$LOCK" || return 1
  perl -MFcntl=:flock -e \
    'open(my $l, ">&=", 9) or exit 2; flock($l, LOCK_EX | LOCK_NB) or exit 1' \
    || return 1
  echo "$$" >"$LOCK"
}

# A kernel flock on fd 9. Every child inherits the fd, so the lock lasts until
# the script AND its ffmpeg and transcription children are all gone: a kill -9
# of the script alone cannot leave orphans unguarded. Nothing goes stale, since
# the kernel releases it once they are gone. The .lock file stays behind on
# purpose: deleting it would let two runs lock different files.
acquire_lock() {
  local owner signal
  try_lock && return 0
  sleep 1   # a run that only just started may not have written its PID yet
  owner=$(cat "$LOCK" 2>/dev/null)
  if kill -0 "$owner" 2>/dev/null; then
    echo "ERROR: '$NAME' is in use by PID $owner. Stop that run first." >&2
    exit 1
  fi
  # The owner was killed but its children hold the lock. Stop them so this run
  # replaces them; ffmpeg finalizes its segment on TERM.
  log "WARNING: previous run (PID ${owner:-unknown}) died; stopping what it left"
  for signal in TERM KILL; do
    exec 9>&-   # so lsof lists only the leftovers, not this script
    lsof -t "$LOCK" 2>/dev/null | xargs kill -"$signal" 2>/dev/null
    for _ in 1 2 3 4 5; do
      sleep 1
      try_lock && return 0
      exec 9>&-
    done
  done
  log "ERROR: could not stop leftovers of the previous run; see: lsof $LOCK"
  exit 1
}

ensure_model() {
  [ -s "$MODEL_FILE" ] && return 0
  log "Downloading whisper model $MODEL (once only)"
  mkdir -p "$MODEL_DIR"
  if curl -fsSL --retry 3 -C - -o "$MODEL_FILE.part" "$MODEL_URL" 2>>"$LOG"; then
    mv "$MODEL_FILE.part" "$MODEL_FILE"
  else
    log "WARNING: model download failed; audio is safe"
    return 1
  fi
}

# macOS hands back pure silence, not an error, when mic permission is denied.
check_mic() {
  local level
  # Without permission ffmpeg can also hang forever, hence the hard timeout.
  level=$(perl -e 'alarm shift; exec @ARGV' 15 ffmpeg -nostdin -hide_banner \
    -f avfoundation -i ":$MIC" -t 3 -af volumedetect -f null - 2>&1 \
    | sed -n 's/.*max_volume: \(.*\) dB.*/\1/p')
  if [ -z "$level" ]; then
    log "ERROR: could not read mic '$MIC'. Nothing is being recorded."
    log "Allow this terminal app in System Settings > Privacy & Security >"
    log "Microphone, then restart it. Run from Ghostty or Terminal, not an"
    log "editor's task runner. Device list:"
    ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 | grep -A9 'audio devices'
    exit 1
  fi
  log "Mic check: peak ${level} dB"
  case "$level" in
    -inf|-9[0-9]*)
      if [ "${ALLOW_SILENT_MIC:-}" != 1 ]; then
        log "ERROR: mic is silent. Nothing is being recorded. Check System"
        log "Settings > Privacy > Microphone, or set ALLOW_SILENT_MIC=1."
        exit 1
      fi
      log "WARNING: mic is silent; recording anyway (ALLOW_SILENT_MIC=1)" ;;
  esac
}

rebuild_transcript() {
  local f base stamp
  {
    for f in "$TEXT"/seg-*.txt; do
      [ -f "$f" ] || continue
      base=$(basename "$f" .txt)
      stamp=${base##*-}
      echo "[${stamp:0:2}:${stamp:2:2}:${stamp:4:2}]"
      cat "$f"
      echo
    done
  } > "$TRANSCRIPT.tmp" && mv "$TRANSCRIPT.tmp" "$TRANSCRIPT"
}

transcribe_one() {
  local src="$1" base out size
  base=$(basename "$src" .flac)
  out="$TEXT/$base"
  [ -f "$out.txt" ] && return 0
  size=$(stat -f%z "$src" 2>/dev/null || echo 0)
  [ "$size" -lt "$MIN_SEGMENT_BYTES" ] && return 0
  # whisper-cli rejects FLAC segments that lack a final header, and those from
  # a crash are truncated too. ffmpeg decodes both, so hand whisper a WAV.
  if ffmpeg -nostdin -loglevel error -y -i "$src" -ar 16000 -ac 1 \
      -c:a pcm_s16le "$out.part.wav" >>"$LOG" 2>&1 \
      && nice -n 15 whisper-cli -m "$MODEL_FILE" -f "$out.part.wav" -l en \
      -t "$THREADS" -np -nt -otxt -of "$out.part" >>"$LOG" 2>&1 \
      && [ -f "$out.part.txt" ]; then
    rm -f "$out.part.wav"
    mv "$out.part.txt" "$out.txt"
    rebuild_transcript
    log "Transcribed $base"
  else
    rm -f "$out.part.txt" "$out.part.wav"
    log "WARNING: transcription failed for $base; its audio is safe"
  fi
}

# Transcribe all segments but the newest $1; ffmpeg may still be writing those.
transcribe_pending() {
  local keep="$1" files=("$AUDIO"/seg-*.flac) i
  [ -e "${files[0]}" ] || return 0
  for ((i = 0; i < ${#files[@]} - keep; i++)); do
    transcribe_one "${files[$i]}"
  done
}

count_untranscribed() {
  local f size count=0
  for f in "$AUDIO"/seg-*.flac; do
    [ -f "$f" ] || continue
    [ -f "$TEXT/$(basename "$f" .flac).txt" ] && continue
    size=$(stat -f%z "$f" 2>/dev/null || echo 0)
    [ "$size" -lt "$MIN_SEGMENT_BYTES" ] || count=$((count + 1))
  done
  echo "$count"
}

# One final pass with no retry, so report anything it could not finish.
finish_transcription() {
  local missing
  [ -s "$MODEL_FILE" ] && transcribe_pending 0
  rebuild_transcript
  missing=$(count_untranscribed)
  [ "$missing" -eq 0 ] && return 0
  log "ERROR: $missing segment(s) not transcribed; the audio is safe."
  log "Recover with: $0 --transcribe $NAME"
  return 1
}

# The model downloads here, never in front of the recording. Failures are
# retried on the next pass until recording stops.
transcribe_loop() {
  while [ ! -f "$STOP_FILE" ]; do
    if ensure_model; then
      transcribe_pending 1
      sleep 5
    else
      sleep 30
    fi
  done
}

# Newest position in the progress file, which grows too large to read whole.
# ffmpeg keeps rewriting this file during a hung input, so only the value shows
# that audio is moving. Empty until ffmpeg opens the file, N/A early on.
recorded_position() {
  tail -n 40 "$PROGRESS" 2>/dev/null | sed -n 's/^out_time_us=//p' | tail -n 1
}

# Loudest reading in the last second, in whole dB. Empty if there are none yet.
recent_peak() {
  tail -n 4 "$LEVELS" 2>/dev/null | awk -F= '/Peak_level/ {
    v = ($2 ~ /inf/) ? -120 : $2 + 0
    if (!n++ || v > m) m = v
  } END { if (n) printf "%d\n", m }'
}

# 20 columns, from -60 dB (empty) to 0 dB (full).
level_bar() {
  local filled=$((($1 + 60) / 3)) on off
  [ "$filled" -lt 0 ] && filled=0
  [ "$filled" -gt 20 ] && filled=20
  printf -v on '%*s' "$filled" ''
  printf -v off '%*s' $((20 - filled)) ''
  printf '%s%s' "${on// /#}" "${off// /-}"
}

# Reads only; a problem here must never reach the recording. Drawn from the
# supervision loop because that already runs every tick for the whole recording.
show_status() {
  local now="$1" peak level segments texts queued seconds=0 words activity
  local prefix color line width
  [ -t 1 ] || return 0

  peak=$(recent_peak)
  if [ -n "$peak" ]; then
    level="[$(level_bar "$peak")] $peak dB"
  else
    level="[level unavailable]"
  fi
  if [ -n "$peak" ] && [ "$peak" -lt "$SILENT_DB" ]; then
    SILENT_SINCE=${SILENT_SINCE:-$now}
  else
    SILENT_SINCE=""
  fi

  segments=("$AUDIO"/seg-*.flac)
  texts=("$TEXT"/seg-*.txt)
  [ -e "${texts[0]}" ] || texts=()
  queued=$((${#segments[@]} - 1 - ${#texts[@]}))
  [ "$queued" -lt 0 ] && queued=0
  activity="$queued queued"
  [ -n "$(printf '%s' "$TEXT"/*.part.wav | sed '/\*/d')" ] && activity="transcribing, $activity"

  case "$POSITION" in
    ''|*[!0-9]*) ;;
    *) seconds=$((POSITION / 1000000)) ;;
  esac
  words=$(tail -n 8 "$TRANSCRIPT" 2>/dev/null | sed '/^\[[0-9:]*\]$/d' | tr -s '\n ' ' ')

  printf -v prefix 'REC %02d:%02d:%02d' $((seconds / 3600)) $((seconds / 60 % 60)) $((seconds % 60))
  color=32
  if [ $((now - MOVED)) -ge "$NO_AUDIO_ALERT_SECONDS" ]; then
    prefix="NO AUDIO FOR $((now - MOVED))s"
    color=31
  elif [ -n "$SILENT_SINCE" ] && [ $((now - SILENT_SINCE)) -ge "$SILENT_ALERT_SECONDS" ]; then
    prefix="SILENT FOR $((now - SILENT_SINCE))s"
    color=31
  fi

  line="$level | ${#texts[@]}/${#segments[@]} segments, $activity | restarts $RESTARTS"
  width=$(($(tput cols 2>/dev/null || echo 80) - ${#prefix} - ${#line} - 6))
  # Wider terminals get the end of the latest words, proof that speech is heard.
  if [ "$width" -gt 0 ] && [ "${#words}" -gt "$width" ]; then
    words=${words: -$width}
  elif [ "$width" -le 0 ]; then
    words=""
  fi
  line="${line:0:$(($(tput cols 2>/dev/null || echo 80) - ${#prefix} - 2))}"
  printf '\r\033[K\033[1;%sm%s\033[0m %s' "$color" "$prefix" "$line"
  [ -n "$words" ] && printf ' | %s' "$words"
  return 0
}

mkdir -p "$AUDIO" "$TEXT"
ensure_tools
acquire_lock
rm -f "$STOP_FILE"   # only after the lock: it may belong to a live run

if [ "$MODE" = transcribe ]; then
  ensure_model
  finish_transcription || exit 1
  log "Done: $TRANSCRIPT"
  exit 0
fi

if [ -n "${TEST_AUDIO:-}" ]; then
  INPUT_ARGS=(-re -stream_loop -1 -i "$TEST_AUDIO")
else
  check_mic
  INPUT_ARGS=(-thread_queue_size 4096 -f avfoundation -i ":$MIC")
fi
caffeinate -ims -w $$ &

transcribe_loop &
TRANSCRIBE_PID=$!

# mktemp's path needs no escaping, unlike $DIR, inside the filter string below.
LEVELS=$(mktemp -t record-talk-levels)
METER_FILTER="aresample=16000,asetnsamples=n=8000:p=0,astats=metadata=1:reset=1:measure_perchannel=none:measure_overall=Peak_level,ametadata=mode=print:key=lavfi.astats.Overall.Peak_level:file=$LEVELS:direct=1"

STOPPING=0
FFMPEG_PID=""
RESTARTS=0
SILENT_SINCE=""
request_stop() {
  [ "$STOPPING" = 1 ] && return
  STOPPING=1
  [ -n "$FFMPEG_PID" ] && kill -TERM "$FFMPEG_PID" 2>/dev/null
}
trap request_stop INT TERM HUP

log "Recording to $DIR  (Ctrl-C to stop)"

while [ "$STOPPING" = 0 ]; do
  rm -f "$PROGRESS"   # a leftover must not read as this ffmpeg's position
  : > "$LEVELS"
  # A second signal makes ffmpeg abandon its buffered tail, up to 256 KiB of
  # audio, so it gets its own process group: Ctrl-C reaches only this script,
  # and request_stop sends the one TERM.
  perl -e 'setpgrp(0, 0); exec @ARGV' ffmpeg -nostdin -hide_banner -loglevel warning \
    "${INPUT_ARGS[@]}" \
    -af "$METER_FILTER" -ac 1 -ar 16000 -c:a flac \
    -progress "$PROGRESS" \
    -f segment -segment_time "$SEGMENT_SECONDS" -reset_timestamps 1 \
    -strftime 1 "$AUDIO/seg-%Y%m%d-%H%M%S.flac" >>"$LOG" 2>&1 &
  FFMPEG_PID=$!
  POSITION=""
  STARTED=$(date +%s)
  MOVED=$STARTED

  # ffmpeg can hang with the mic gone while the process stays alive, either
  # mid-recording or before it ever opens the progress file.
  while kill -0 "$FFMPEG_PID" 2>/dev/null; do
    sleep 1
    NOW=$(date +%s)
    CURRENT=$(recorded_position)
    if [ "$CURRENT" != "$POSITION" ]; then
      POSITION=$CURRENT
      MOVED=$NOW
    elif [ $((NOW - MOVED)) -gt "$STALL_SECONDS" ]; then
      log "WARNING: recording stalled, restarting ffmpeg"
      kill -9 "$FFMPEG_PID" 2>/dev/null
      break
    fi
    show_status "$NOW"
  done

  wait "$FFMPEG_PID" 2>/dev/null
  STATUS=$?
  FFMPEG_PID=""
  if [ "$STOPPING" = 0 ]; then
    RESTARTS=$((RESTARTS + 1))
    log "WARNING: ffmpeg exited ($STATUS), restarting in 2s"
    # The meter is the only optional part of this command, so it goes first.
    if [ $(($(date +%s) - STARTED)) -lt 5 ] && [ "$METER_FILTER" != anull ]; then
      METER_FILTER=anull
      log "WARNING: ffmpeg died at startup; retrying without the level meter"
    fi
    sleep 2
  fi
done

trap '' INT TERM HUP
log "Stopped recording; finishing transcript"
touch "$STOP_FILE"
pkill -f "$MODEL_FILE.part" 2>/dev/null
wait "$TRANSCRIBE_PID" 2>/dev/null
rm -f "$PROGRESS" "$STOP_FILE" "$LEVELS"
finish_transcription
STATUS=$?
log "Transcript: $TRANSCRIPT"
log "Audio: $AUDIO"
exit "$STATUS"
