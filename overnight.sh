#!/bin/bash
# agx-probe overnight supervisor.
# Runs the probe queue repeatedly, three times per probe so reproducibility can be
# computed, and recovers from the GPU wedges this method reliably causes:
# raw patching writes arbitrary bytes into command memory and some streams never
# retire. Without recovery an overnight run dies on the first hang.

cd "$(dirname "$0")" || exit 1
OUT=results/overnight
mkdir -p "$OUT"
LOG="$OUT/supervisor.log"
say(){ echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

TIMEOUT=${TIMEOUT:-420}
REPS=${REPS:-3}
PROBES="wide_probe validate_all validate_sampler validate_pass state_probe pass_probe sampler_probe pso_probe isa_probe isa2_probe ring_probe"

# run one probe with a hard timeout; 0=ok 1=timeout
run_bounded(){
  local bin=$1 dest=$2 t=0
  ./build/"$bin" > "$dest" 2>"${dest%.txt}.err" &
  local pid=$!
  while kill -0 $pid 2>/dev/null; do
    sleep 5; t=$((t+5))
    if [ $t -ge "$TIMEOUT" ]; then kill -9 $pid 2>/dev/null; wait $pid 2>/dev/null; return 1; fi
  done
  wait $pid 2>/dev/null; return 0
}

# after a kill the GPU queue is usually wedged; wait, then confirm with a probe
# known to finish in under a second before continuing
gpu_recover(){
  say "  recovering GPU"
  pkill -9 -f 'build/(validate|state_probe|pass_probe|sampler_probe|pso_probe|isa|ring)' 2>/dev/null
  for w in 1 2 3 4 5 6; do
    sleep 10
    ./build/cull_probe > /tmp/agx_health.out 2>&1 &
    local p=$!; local t=0
    while kill -0 $p 2>/dev/null && [ $t -lt 20 ]; do sleep 2; t=$((t+2)); done
    if kill -0 $p 2>/dev/null; then kill -9 $p 2>/dev/null; say "  still wedged (attempt $w)"; else say "  GPU healthy"; return 0; fi
  done
  say "  GPU DID NOT RECOVER - pausing 5 min"; sleep 300; return 1
}

gpuev(){ ls /Library/Logs/DiagnosticReports/gpuEvent-* 2>/dev/null | wc -l | tr -d ' '; }
GPU0=$(gpuev)
say "GPU fault reports at start: $GPU0"
say "=== overnight run starting: ${REPS} reps x $(echo $PROBES|wc -w|tr -d ' ') probes, ${TIMEOUT}s cap ==="
CYCLE=0
while true; do
  CYCLE=$((CYCLE+1))
  say "--- cycle $CYCLE ---"
  for p in $PROBES; do
    [ -x "./build/$p" ] || continue
    for r in $(seq 1 $REPS); do
      d="$OUT/${p}.c${CYCLE}r${r}.txt"
      if run_bounded "$p" "$d"; then
        n=$(grep -c CAUSAL "$d" 2>/dev/null); n=${n:-0}
        say "  $p rep$r ok (${n} causal lines)"
      else
        say "  $p rep$r TIMED OUT after ${TIMEOUT}s"
        gpu_recover
      fi
      G=$(gpuev); if [ "$G" -gt "$GPU0" ]; then
        say "    +$((G-GPU0)) GPU fault report(s) during $p  <-- desktop may have glitched"
        GPU0=$G
      fi
    done
  done
  # reproducibility: offsets appearing in every rep of the latest cycle
  for p in $PROBES; do
    ls "$OUT/${p}.c${CYCLE}r"*.txt >/dev/null 2>&1 || continue
    cat "$OUT/${p}.c${CYCLE}r"*.txt 2>/dev/null | grep -oE '0x[0-9a-f]{3,6}' | sort | uniq -c \
      | awk -v n="$REPS" -v p="$p" '$1>=n {print p, $2}' >> "$OUT/stable-offsets.txt"
  done
  say "cycle $CYCLE done; stable offsets so far: $(sort -u "$OUT/stable-offsets.txt" 2>/dev/null | wc -l | tr -d ' ')"
done
