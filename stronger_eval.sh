#!/bin/bash
# Stronger eval: harder, deeper tests for local Ollama models.
# Asks for: GPU memory limit, context size, models, reasoning effort, runs per item
# and which test items to run. Runs everything, grades automatically, prints scores
# by skill area and writes a blind judge pack for the open-ended items.
# Needs stronger_eval.py in the same folder.
# Usage:  bash stronger_eval.sh

cd "$(dirname "$0")" || exit 1

# Keep the Mac awake (no system, idle, disk or display sleep) until this script ends,
# including the questions, the Ollama restart and every model run.
caffeinate -dims -w $$ &

EVAL="$(pwd)/stronger_eval.py"
if [ ! -f "$EVAL" ]; then
  echo "stronger_eval.py must be in the same folder as this script."; exit 1
fi
if ! python3 -c "print(1)" >/dev/null 2>&1; then
  echo "Python 3 is needed (it runs the tests and grading). Install it, then run this again."; exit 1
fi

line() { echo "------------------------------------------------------------"; }

echo ""
echo "============================================================"
echo "  Stronger eval: harder tests for local models (Ollama)"
echo "  Answer each question, or press Return to accept the default."
echo "============================================================"

# ---------------------------------------------------------------
# 1. GPU memory limit
# ---------------------------------------------------------------
echo ""
line
echo "STEP 1 of 6: GPU memory limit"
line
echo "How much of your 24 GB may the GPU use for models?"
echo "  1) Keep the macOS default (about 16 GB)"
echo "  2) 19 GB  - recommended for models of 15-18 GB (asks for your Mac password)"
echo "  3) Enter my own value in MB (do not go above 20480 on a 24 GB Mac)"
read -r -p "Choose 1, 2 or 3 [default 2]: " gpu_choice
case "${gpu_choice:-2}" in
  1) GPU_LIMIT="" ;;
  3) read -r -p "Enter the limit in MB (e.g. 18432 for 18 GB): " GPU_LIMIT ;;
  *) GPU_LIMIT=19456 ;;
esac

# ---------------------------------------------------------------
# 2. Context size
# ---------------------------------------------------------------
echo ""
line
echo "STEP 2 of 6: Context size (how many tokens the model can hold: question + thinking + answer)"
line
echo "  1) 4096   - Ollama default, least memory, long thinking may get cut off"
echo "  2) 8192   - good for most questions"
echo "  3) 12288  - recommended for models that think a lot (e.g. Qwen)"
echo "  4) 16384  - for long code or documents (uses more memory)"
echo "  5) Enter my own value"
read -r -p "Choose 1-5 [default 3]: " ctx_choice
case "${ctx_choice:-3}" in
  1) CONTEXT=4096 ;;
  2) CONTEXT=8192 ;;
  4) CONTEXT=16384 ;;
  5) read -r -p "Enter the context size in tokens (e.g. 10000): " CONTEXT ;;
  *) CONTEXT=12288 ;;
esac

# ---------------------------------------------------------------
# Start Ollama now so we can list the models
# ---------------------------------------------------------------
echo ""
echo "Restarting Ollama with a ${CONTEXT}-token context (a clean start avoids memory errors)..."
launchctl setenv OLLAMA_CONTEXT_LENGTH "$CONTEXT"
pkill -f ollama >/dev/null 2>&1; pkill -f Ollama >/dev/null 2>&1; sleep 3
open -a Ollama
for i in $(seq 1 30); do ollama list >/dev/null 2>&1 && break; sleep 1; done
if ! ollama list >/dev/null 2>&1; then
  echo "Ollama did not start. Open the Ollama app and run this script again."
  exit 1
fi

# ---------------------------------------------------------------
# 3. Models
# ---------------------------------------------------------------
AVAILABLE=()
SIZES=()
while read -r name id size unit rest; do
  [ "$name" = "NAME" ] && continue
  [ -z "$name" ] && continue
  AVAILABLE+=("$name")
  SIZES+=("$size $unit")
done < <(ollama list)

if [ ${#AVAILABLE[@]} -eq 0 ]; then
  echo "No models downloaded. Use 'ollama pull <model>' first."
  exit 1
fi

echo ""
line
echo "STEP 3 of 6: Models to test"
line
echo "Your downloaded models (file size on disk):"
for i in "${!AVAILABLE[@]}"; do
  printf "  %2d) %-50s %s\n" "$((i+1))" "${AVAILABLE[$i]}" "${SIZES[$i]}"
done
echo "Type the numbers separated by spaces, in the order you want them run."
echo "Tip: put the biggest model last. Example: 2 4 1"
CHOSEN=()
while [ ${#CHOSEN[@]} -eq 0 ]; do
  read -r -p "Models: " -a picks
  for n in "${picks[@]}"; do
    if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#AVAILABLE[@]} ]; then
      cand="${AVAILABLE[$((n-1))]}"
      dup=0; for c in "${CHOSEN[@]}"; do [ "$c" = "$cand" ] && dup=1; done
      if [ $dup -eq 1 ]; then echo "  Skipping repeat of $cand (already chosen)."; else CHOSEN+=("$cand"); fi
    else
      echo "  Ignoring '$n' (not a number from the list)."
    fi
  done
  [ ${#CHOSEN[@]} -eq 0 ] && echo "Please choose at least one model."
done

# ---------------------------------------------------------------
# 4. Reasoning effort / thinking for each model
# ---------------------------------------------------------------
echo ""
line
echo "STEP 4 of 6: Reasoning effort for each model"
line
THINK=()
for m in "${CHOSEN[@]}"; do
  echo ""
  if [[ "$m" == *gpt-oss* ]]; then
    echo "$m supports reasoning effort levels:"
    echo "  1) Default (medium)"
    echo "  2) Low    - fastest, shortest thinking"
    echo "  3) Medium"
    echo "  4) High   - most thinking, slower, often more accurate"
    read -r -p "Choose 1-4 [default 1]: " e
    case "${e:-1}" in
      2) THINK+=("low") ;;
      3) THINK+=("medium") ;;
      4) THINK+=("high") ;;
      *) THINK+=("") ;;
    esac
  elif ollama show "$m" 2>/dev/null | grep -qi "thinking"; then
    echo "$m supports thinking on/off (no effort levels):"
    echo "  1) Default (model decides, usually on)"
    echo "  2) Thinking on   - slower, usually more careful"
    echo "  3) Thinking off  - fastest, answers directly"
    read -r -p "Choose 1-3 [default 1]: " e
    case "${e:-1}" in
      2) THINK+=("true") ;;
      3) THINK+=("false") ;;
      *) THINK+=("") ;;
    esac
  else
    echo "$m: no thinking controls (community builds like hf.co/... decide for themselves). Using default."
    THINK+=("")
  fi
done

# ---------------------------------------------------------------
# 5. Runs per item
# ---------------------------------------------------------------
echo ""
line
echo "STEP 5 of 6: Runs per test item"
line
echo "Answers vary from run to run. More runs show how consistent a model is."
echo "  1) 1 run   - quickest (about 15-25 minutes per model for all items)"
echo "  2) 2 runs  - recommended balance"
echo "  3) 3 runs  - most reliable (3x as long as 1 run)"
read -r -p "Choose 1-3 [default 2]: " r
case "${r:-2}" in
  1) RUNS=1 ;;
  3) RUNS=3 ;;
  *) RUNS=2 ;;
esac

# ---------------------------------------------------------------
# 6. Test items
# ---------------------------------------------------------------
IDS=(); CATS=(); TITLES=()
while IFS=$'\t' read -r id cat title; do
  IDS+=("$id"); CATS+=("$cat"); TITLES+=("$title")
done < <(python3 "$EVAL" list)

echo ""
line
echo "STEP 6 of 6: Test items"
line
echo "The ${#IDS[@]} items, by skill area:"
for i in "${!IDS[@]}"; do
  printf "  %2d) %-13s %-14s %s\n" "$((i+1))" "${CATS[$i]}" "${IDS[$i]}" "${TITLES[$i]}"
done
echo "Which to run?"
echo "  a) All ${#IDS[@]} items (default)"
echo "  b) Quick set - one item per skill area (7 items)"
echo "  c) Choose items by number (e.g. 1 3 5 8)"
read -r -p "Choose a, b or c [default a]: " ic
SEL=()
case "${ic:-a}" in
  b|B)
    seen=""
    for i in "${!IDS[@]}"; do
      case "|$seen|" in *"|${CATS[$i]}|"*) ;; *) SEL+=("${IDS[$i]}"); seen="$seen|${CATS[$i]}" ;; esac
    done ;;
  c|C)
    read -r -p "Item numbers: " -a pick
    for n in "${pick[@]}"; do
      if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#IDS[@]} ]; then SEL+=("${IDS[$((n-1))]}"); fi
    done ;;
esac
[ ${#SEL[@]} -eq 0 ] && SEL=("${IDS[@]}")

# ---------------------------------------------------------------
# Confirm
# ---------------------------------------------------------------
TOTAL=$(( ${#CHOSEN[@]} * ${#SEL[@]} * RUNS ))
echo ""
echo "============================================================"
echo "  Summary of your choices"
echo "============================================================"
echo "  GPU limit : ${GPU_LIMIT:-macOS default} ${GPU_LIMIT:+MB}"
echo "  Context   : $CONTEXT tokens"
for i in "${!CHOSEN[@]}"; do
  echo "  Model $((i+1))   : ${CHOSEN[$i]}  (thinking/effort: ${THINK[$i]:-default})"
done
echo "  Items     : ${#SEL[@]}   Runs per item: $RUNS"
echo "  Answers   : $TOTAL  (roughly $(( TOTAL * 45 / 60 )) minutes at ~45 s per answer)"
echo ""
echo "  Staying awake: ON (caffeinate keeps the Mac and screen awake until the run ends)."
echo "  Keep the lid OPEN - closing it sleeps a MacBook even with caffeinate."
if ! pmset -g batt 2>/dev/null | grep -q "AC Power"; then
  echo "  WARNING: the Mac is on battery. Plug in the charger - long runs drain the battery"
  echo "  and macOS may sleep or slow down on low battery."
fi
read -r -p "Start? (y/n) [default y]: " go
[[ "${go:-y}" =~ ^[nN] ]] && { echo "Cancelled."; launchctl unsetenv OLLAMA_CONTEXT_LENGTH; exit 0; }

# ---------------------------------------------------------------
# Run
# ---------------------------------------------------------------
if [ -n "$GPU_LIMIT" ]; then
  echo "Setting the GPU limit to $GPU_LIMIT MB (enter your Mac password if asked)..."
  sudo sysctl iogpu.wired_limit_mb="$GPU_LIMIT"
fi

STAMP=$(date +%Y%m%d_%H%M)
OUT="stronger_answers_${STAMP}.txt"
CSV="stronger_scores_${STAMP}.csv"
GPULOG="stronger_gpu_${STAMP}.txt"
TMP=$(mktemp)
echo "model,effort,item,category,run,status,tokens_per_sec,tokens_generated,total_time,result,score,detail" > "$CSV"

( while true; do date "+%H:%M:%S" >> "$GPULOG"; ollama ps >> "$GPULOG"; sleep 5; done ) &
LOGGER=$!
trap 'kill $LOGGER 2>/dev/null; rm -f "$TMP"; launchctl unsetenv OLLAMA_CONTEXT_LENGTH' EXIT
export STRONGER_CTX="$CONTEXT"

done_n=0
for i in "${!CHOSEN[@]}"; do
  m="${CHOSEN[$i]}"; t="${THINK[$i]}"
  case "$t" in true) lbl="thinking-on" ;; false) lbl="thinking-off" ;; "") lbl="default" ;; *) lbl="$t" ;; esac
  THINK_ARG=(); [ -n "$t" ] && THINK_ARG=(--think="$t")
  for id in "${SEL[@]}"; do
    PROMPT="$(python3 "$EVAL" prompt "$id")"
    cat=""; for k in "${!IDS[@]}"; do [ "${IDS[$k]}" = "$id" ] && cat="${CATS[$k]}"; done
    for run in $(seq 1 "$RUNS"); do
      done_n=$((done_n + 1))
      echo "" | tee -a "$OUT"
      echo "==================== $m | effort: $lbl | $id | run $run ====================" | tee -a "$OUT"
      echo "[answer $done_n of $TOTAL]"
      echo "$PROMPT" >> "$OUT"
      echo "${PROMPT:0:200}..."
      ollama run "$m" --verbose --nowordwrap --keepalive 10m "${THINK_ARG[@]}" "$PROMPT" 2>&1 | tee "$TMP"
      cat "$TMP" >> "$OUT"
      CLEAN=$(sed -e $'s/\033\\[[0-9;?]*[a-zA-Z]//g' "$TMP" | tr -d '\r')
      rate=$(echo "$CLEAN" | grep -E '^eval rate:' | awk '{print $3}')
      count=$(echo "$CLEAN" | grep -E '^eval count:' | awk '{print $3}')
      total=$(echo "$CLEAN" | grep -E '^total duration:' | awk '{print $3}')
      if [ -n "$rate" ]; then
        status="ok"
        g=$(python3 "$EVAL" grade "$id" "$TMP" 2>/dev/null | tail -1)
        res="${g%%|*}"; rest="${g#*|}"; score="${rest%%|*}"; detail="${rest#*|}"
        [ -z "$res" ] && { res="ERROR"; score=0; detail="checker failed"; }
      else
        status="FAILED"; res="FAIL"; score=0; detail="model did not finish"
      fi
      echo ">>> Auto-check: $res ($score) - $detail" | tee -a "$OUT"
      echo "\"$m\",\"$lbl\",$id,\"$cat\",$run,$status,$rate,$count,$total,$res,$score,\"${detail//\"/}\"" >> "$CSV"
    done
  done
  ollama stop "$m" >/dev/null 2>&1
  while ollama ps | awk '{print $1}' | grep -qxF "$m"; do sleep 1; done
  sleep 10
done

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
echo ""
echo "============================================================"
echo "  Results"
echo "============================================================"
python3 "$EVAL" summary "$CSV"
echo ""
python3 "$EVAL" judgepack "$OUT" 2>/dev/null || echo "(No Domain-depth items were run, so no judge pack.)"
echo ""
echo "Full answers : $OUT"
echo "Scores CSV   : $CSV  (one row per answer; opens in Numbers or Excel)"
echo "GPU log      : $GPULOG"
echo ""
echo "Domain-depth scores are approximate until judged: send me the *_judge_pack.md file"
echo "for blind scoring, and keep the *_judge_key.csv file to map codes back to models."
echo "Ollama goes back to its default context the next time it restarts."
