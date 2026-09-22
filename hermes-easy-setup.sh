#!/bin/bash
# =============================================================================
#  hermes-easy-setup.sh  —  guided Hermes Agent + local model + Slack installer
#  Author: Rich Olson
#  Target: macOS (Apple Silicon), a user who has never used Terminal.
#
#  Usage:   bash hermes-easy-setup.sh            full guided install
#           bash hermes-easy-setup.sh model      only (re)pick + tune the local model
#           bash hermes-easy-setup.sh slack      only (re)do the Slack connection
#           bash hermes-easy-setup.sh doctor     check everything, change nothing
#
#  Safe to re-run: every step checks what is already done.
#  Written for the stock macOS bash 3.2 — no associative arrays, no mapfile.
# =============================================================================
set -u

HERMES_HOME="$HOME/.hermes"
ENV_FILE="$HERMES_HOME/.env"
MANIFEST="$HERMES_HOME/slack-manifest.json"
LOG="$HERMES_HOME/easy-setup.log"
CTX=65536                      # Hermes refuses to run below 64K context
HDRS="${TMPDIR:-/tmp}/hermes-easy-hdrs.$$"   # fixed path: slack_api runs inside $(…), so it can't hand a variable back
LOCAL_ID="hermes-local"        # stable model name Hermes will be pointed at
REQUIRED_SCOPES="chat:write app_mentions:read channels:history channels:read groups:history groups:read im:history im:read im:write mpim:history mpim:read users:read files:read files:write"
BACKEND=""
BASE_URL=""

# Model catalogue:  min_ram_gb | label | ollama_tag | mlx_repo | why
# Dynamic bounds: Safe memory headroom is calculated dynamically at runtime.
CATALOGUE='
36|Qwen3.6 35B-A3B (best tool use, fast MoE, ~20 GB)|qwen3.6:35b|mlx-community/Qwen3.6-35B-A3B-4bit|recommended
36|Qwen3-Coder 30B-A3B (fastest coding/agent MoE, snappy)|qwen3-coder:30b|mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit|fastest
36|Gemma 4 26B-A4B (fast MoE, good writing & reasoning)|gemma4:26b|mlx-community/gemma-4-26b-a4b-it-4bit|alternative
24|GPT-OSS 20B (fast MoE, 13 GB)|gpt-oss:20b|mlx-community/gpt-oss-20b-MXFP4-Q8|recommended
24|Qwen2.5-Coder 14B (strong coding & tools, 9 GB)|qwen2.5-coder:14b|mlx-community/Qwen2.5-Coder-14B-Instruct-4bit|alternative
16|Hermes 3 3B (Nous Research agent model, ~1.9 GB, safest on 16 GB)|hermes3:3b|mlx-community/Hermes-3-Llama-3.2-3B-4bit|recommended
16|Qwen3 4B (fast agent, ~2.5 GB, 64K context)|qwen3:4b|mlx-community/Qwen3-4B-Instruct-2507-4bit|alternative
16|Qwen2.5-Coder 7B (elite tool use, ~8.3 GB total, close other apps)|qwen2.5-coder:7b|mlx-community/Qwen2.5-Coder-7B-Instruct-4bit|alternative
8|Hermes 3 3B (Nous Research agent model, ~1.9 GB)|hermes3:3b|mlx-community/Hermes-3-Llama-3.2-3B-4bit|recommended
8|Qwen3 4B (small, basic tool use only)|qwen3:4b|mlx-community/Qwen3-4B-Instruct-2507-4bit|alternative
'

# ------------------------------------------------------------------ helpers --
B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'; N=$'\033[0m'
step()  { echo; echo "${B}${C}━━ $* ━━${N}"; }
ok()    { echo "  ${G}✔${N} $*"; }
warn()  { echo "  ${Y}!${N} $*"; }
bad()   { echo "  ${R}✘${N} $*"; }
info()  { echo "    $*"; }
die()   { echo; bad "$*"; echo "    See the log file: $LOG"; exit 1; }
pause() { echo; read -r -p "    Press Return when done… " _; }
ask()   { local a; read -r -p "    $1 " a; echo "$a"; }
yesno() { local a; read -r -p "    $1 [Y/n] " a; case "$a" in n*|N*) return 1;; *) return 0;; esac; }
have()  { command -v "$1" >/dev/null 2>&1; }
trim()  { echo "$1" | tr -d '[:space:]'; }

# json <python-expression-on-d>   — reads JSON from stdin, prints the expression
json()  { python3 -c "import sys,json
try:
    d=json.load(sys.stdin); v=($1); print('' if v is None else v)
except Exception: print('')"; }

set_env() {   # set_env KEY VALUE  — idempotent update of ~/.hermes/.env
  mkdir -p "$HERMES_HOME"; touch "$ENV_FILE"; chmod 600 "$ENV_FILE"
  grep -v "^$1=" "$ENV_FILE" > "$ENV_FILE.tmp" 2>/dev/null || true
  echo "$1=$2" >> "$ENV_FILE.tmp"; mv "$ENV_FILE.tmp" "$ENV_FILE"; chmod 600 "$ENV_FILE"
}
get_env() { [ -f "$ENV_FILE" ] && grep "^$1=" "$ENV_FILE" | tail -1 | cut -d= -f2-; }

slack_api() { # slack_api TOKEN METHOD [curl args…]  -> body on stdout, headers in $HDRS
  local tok="$1" method="$2"; shift 2
  curl -sS -D "$HDRS" -X POST -H "Authorization: Bearer $tok" "$@" "https://slack.com/api/$method"
}

# -------------------------------------------------- canary memory watchdog --
WATCHDOG_PID=""
WATCHDOG_FLAG="${TMPDIR:-/tmp}/hermes_canary_abort.$$"

watchdog_start() {
  local target_port="$1" # 1234 or 11434
  local max_rss_kb="${2:-$MAX_SAFE_RSS_KB}"
  rm -f "$WATCHDOG_FLAG"

  (
    local s_pid=""
    for _ in 1 2 3 4 5; do
      s_pid="$(lsof -ti :"$target_port" 2>/dev/null | head -n 1)"
      [ -n "$s_pid" ] && break
      sleep 0.2
    done
    [ -z "$s_pid" ] && exit 0

    while true; do
      # Query total RSS (in KB) of the server process tree
      local rss
      rss="$(ps -o rss= -p "$s_pid" $(pgrep -P "$s_pid" 2>/dev/null) 2>/dev/null | awk '{s+=$1} END {print s}')"
      if [ -n "$rss" ] && [ "$rss" -gt "$max_rss_kb" ]; then
        # MEMORY CEILING BREACH: Emergency shutdown to prevent kernel panic
        echo "$rss" > "$WATCHDOG_FLAG"
        if [ "$target_port" = 1234 ]; then
          lms unload --all >/dev/null 2>&1 || true
        elif [ "$target_port" = 11434 ]; then
          ollama stop "$LOCAL_ID" >/dev/null 2>&1 || true
        fi
        kill -STOP "$s_pid" 2>/dev/null || true
        sleep 0.5
        kill -CONT "$s_pid" 2>/dev/null || true
        exit 1
      fi
      sleep 0.25
    done
  ) &
  WATCHDOG_PID=$!
}

watchdog_stop() {
  if [ -n "$WATCHDOG_PID" ]; then
    kill "$WATCHDOG_PID" 2>/dev/null || true
    wait "$WATCHDOG_PID" 2>/dev/null || true
    WATCHDOG_PID=""
  fi
}

trap 'watchdog_stop; rm -f "$WATCHDOG_FLAG" "$HDRS"' EXIT INT TERM

# --------------------------------------------------------------- 0 preflight --
preflight() {
  step "Step 0 · Checking this Mac"
  [ "$(uname -s)" = "Darwin" ] || die "This script is for macOS."
  mkdir -p "$HERMES_HOME"; : >> "$LOG"
  export PATH="$HOME/.local/bin:$HOME/.cache/lm-studio/bin:$HOME/.lmstudio/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

  if ! xcode-select -p >/dev/null 2>&1; then
    warn "Apple's developer tools are needed (one-time, free, ~5 min)."
    info "A window will pop up — click ${B}Install${N}, wait for it to finish."
    xcode-select --install >/dev/null 2>&1
    until xcode-select -p >/dev/null 2>&1; do sleep 10; printf "."; done; echo
  fi
  ok "Developer tools present"

  ARCH="$(uname -m)"
  CHIP="$(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
  TOTAL_RAM_BYTES="$(sysctl -n hw.memsize 2>/dev/null || echo 17179869184)"
  RAM_GB=$(( TOTAL_RAM_BYTES / 1073741824 ))
  DISK_GB=$(df -g "$HOME" | awk 'NR==2{print $4}')

  # Dynamic unified memory bounds analysis:
  # macOS kernel, WindowServer, Slack, IDE and running apps require dedicated headroom.
  # Reserving minimum 4.5 GB on 16 GB systems, 35% on medium systems, capped at 10 GB on high-memory systems.
  TOTAL_RAM_KB=$(( TOTAL_RAM_BYTES / 1024 ))
  SYSTEM_RESERVE_KB=$(( TOTAL_RAM_KB * 35 / 100 ))
  [ "$SYSTEM_RESERVE_KB" -lt 4718592 ] && SYSTEM_RESERVE_KB=4718592   # minimum 4.5 GB reserved for OS/apps
  [ "$SYSTEM_RESERVE_KB" -gt 10485760 ] && SYSTEM_RESERVE_KB=10485760 # cap reserve at 10 GB
  MAX_SAFE_RSS_KB=$(( TOTAL_RAM_KB - SYSTEM_RESERVE_KB ))
  MAX_SAFE_RSS_GB=$(( MAX_SAFE_RSS_KB / 1048576 ))
  SYSTEM_RESERVE_GB=$(( SYSTEM_RESERVE_KB / 1048576 ))

  # Hardware profiling for Hermes Agent & 64K context
  if [ "$RAM_GB" -ge 48 ]; then
    HW_PROFILE="High-Capacity MoE Profile (48+ GB Unified Memory)"
    HW_MEM_NOTE="Substantial headroom (${MAX_SAFE_RSS_GB} GB model budget): 30B-35B MoE models run with dedicated GPU acceleration."
  elif [ "$RAM_GB" -ge 32 ]; then
    HW_PROFILE="Mid-High Tier Profile (32-36 GB Unified Memory)"
    HW_MEM_NOTE="Comfortably runs compact 26B-35B MoE models or 14B dense models (${MAX_SAFE_RSS_GB} GB model budget)."
  elif [ "$RAM_GB" -ge 24 ]; then
    HW_PROFILE="Mid-Tier Profile (24 GB Unified Memory)"
    HW_MEM_NOTE="Well suited for 14B models or compact MoEs like GPT-OSS 20B (${MAX_SAFE_RSS_GB} GB model budget)."
  elif [ "$RAM_GB" -ge 16 ]; then
    HW_PROFILE="16 GB Apple Silicon Profile (Constraint-Aware)"
    HW_MEM_NOTE="Calculated safe model ceiling: ${MAX_SAFE_RSS_GB} GB (reserving ${SYSTEM_RESERVE_GB} GB for macOS). Real-time Canary Watchdog active."
  else
    HW_PROFILE="Compact / 8 GB Profile"
    HW_MEM_NOTE="Memory-constrained (${MAX_SAFE_RSS_GB} GB model budget): requires ultra-compact models and minimal background apps."
  fi

  ok "$CHIP · ${RAM_GB} GB RAM (${MAX_SAFE_RSS_GB} GB model budget, ${SYSTEM_RESERVE_GB} GB OS reserve) · ${DISK_GB} GB free disk"
  info "Hardware profile: ${B}${HW_PROFILE}${N}"
  info "$HW_MEM_NOTE"

  if [ "$DISK_GB" -lt 15 ]; then
    warn "Only ${DISK_GB} GB free disk — downloads may fail if disk fills up."
  elif [ "$DISK_GB" -lt 30 ]; then
    info "Note: ${DISK_GB} GB free disk — enough for compact 3B-8B models, but 35B models require ~20 GB."
  fi
}

# ------------------------------------------------------------ 1 pick backend --
detect_backend() {
  step "Step 1 · Finding your local AI engine"
  HAS_LMS=0; HAS_OLLAMA=0
  if have lms; then
    HAS_LMS=1
  elif [ -x "$HOME/.cache/lm-studio/bin/lms" ]; then
    export PATH="$HOME/.cache/lm-studio/bin:$PATH"; HAS_LMS=1
  elif [ -x "$HOME/.lmstudio/bin/lms" ]; then
    export PATH="$HOME/.lmstudio/bin:$PATH"; HAS_LMS=1
  fi
  [ $HAS_LMS -eq 0 ] && [ -d "/Applications/LM Studio.app" ] && HAS_LMS=2   # installed, never opened
  if have ollama || [ -d "/Applications/Ollama.app" ]; then HAS_OLLAMA=1; fi
  [ $HAS_OLLAMA -eq 1 ] && ! have ollama && export PATH="/Applications/Ollama.app/Contents/Resources:$PATH"

  if [ $HAS_LMS -eq 2 ]; then
    warn "LM Studio is installed but has never been opened. Opening it now…"
    open -a "LM Studio"; info "Wait for its window to appear, skip any welcome screens."
    pause
    if have lms; then HAS_LMS=1
    elif [ -x "$HOME/.cache/lm-studio/bin/lms" ]; then export PATH="$HOME/.cache/lm-studio/bin:$PATH"; HAS_LMS=1
    elif [ -x "$HOME/.lmstudio/bin/lms" ]; then export PATH="$HOME/.lmstudio/bin:$PATH"; HAS_LMS=1
    else HAS_LMS=0; fi
  fi
  [ $HAS_LMS -eq 1 ]    && ok "LM Studio found"
  [ $HAS_OLLAMA -eq 1 ] && ok "Ollama found"

  if [ "${HERMES_BACKEND:-}" != "" ]; then
    BACKEND="$HERMES_BACKEND"
  elif [ $HAS_LMS -eq 1 ] && [ $HAS_OLLAMA -eq 1 ]; then
    info "Both LM Studio and Ollama are available."
    if [ "$RAM_GB" -lt 24 ]; then
      info "  ${B}1)${N} Ollama (Recommended on ${RAM_GB} GB Macs: 8-bit quantized Metal KV cache prevents memory exhaustion at 64K context)"
      info "  ${B}2)${N} LM Studio (MLX engine: unquantized KV cache; auto-balanced GPU offload applied)"
      local be_pick; be_pick="$(ask "Which engine would you like to use? [1 or 2, default: 1]:")"
      case "${be_pick:-1}" in
        2|lmstudio|LMStudio|lm-studio) BACKEND=lmstudio;;
        *) BACKEND=ollama;;
      esac
    else
      info "  ${B}1)${N} LM Studio (Recommended on ${RAM_GB} GB Macs: native Apple Silicon MLX engine)"
      info "  ${B}2)${N} Ollama"
      local be_pick; be_pick="$(ask "Which engine would you like to use? [1 or 2, default: 1]:")"
      case "${be_pick:-1}" in
        2|ollama|Ollama) BACKEND=ollama;;
        *) BACKEND=lmstudio;;
      esac
    fi
  elif [ "$ARCH" = "arm64" ] && [ $HAS_OLLAMA -eq 1 ] && [ "$RAM_GB" -lt 24 ]; then
    BACKEND=ollama
  elif [ "$ARCH" = "arm64" ] && [ $HAS_LMS -eq 1 ] && [ "$RAM_GB" -ge 24 ]; then
    BACKEND=lmstudio
  elif [ $HAS_OLLAMA -eq 1 ]; then
    BACKEND=ollama
  elif [ $HAS_LMS -eq 1 ]; then
    BACKEND=lmstudio
  else
    warn "Neither Ollama nor LM Studio is installed. Opening the LM Studio download page."
    info "Download LM Studio for Mac, drag it to Applications, open it once, then come back here."
    open "https://lmstudio.ai"; pause
    export PATH="$HOME/.cache/lm-studio/bin:$HOME/.lmstudio/bin:$PATH"
    if have lms || [ -d "/Applications/LM Studio.app" ]; then
      BACKEND=lmstudio
    else
      warn "LM Studio not detected. Checking Ollama as fallback…"
      open "https://ollama.com/download"; pause
      export PATH="/Applications/Ollama.app/Contents/Resources:$PATH"
      have ollama || die "Still can't find LM Studio or Ollama."
      BACKEND=ollama
    fi
  fi
  if [ "$BACKEND" = lmstudio ]; then
    ok "Using ${B}LM Studio${N} — dynamic GPU offload and active canary watchdog applied"
    BASE_URL="http://localhost:1234/v1"
  else
    ok "Using ${B}Ollama${N} — Metal acceleration with 8-bit quantized KV cache"
    BASE_URL="http://localhost:11434/v1"
  fi
}

# -------------------------------------------------------------- 2 pick model --
exists_online() { # exists_online ROW  -> 0 if downloadable for the active backend
  local tag repo; tag="$(echo "$1" | cut -d'|' -f3)"; repo="$(echo "$1" | cut -d'|' -f4)"
  if [ "$BACKEND" = lmstudio ]; then
    [ "$(curl -s -o /dev/null -w '%{http_code}' "https://huggingface.co/api/models/$repo")" = 200 ]
  else
    [ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
        "https://registry.ollama.ai/v2/library/${tag%%:*}/manifests/${tag##*:}")" = 200 ]
  fi
}

pick_model() {
  step "Step 2 · Choosing the best model for ${RAM_GB} GB of memory"
  # Tier = largest min_ram that fits. Model + 64K KV cache must stay under ~60% of RAM.
  TIER=8; for t in 16 24 36; do [ "$RAM_GB" -ge "$t" ] && TIER=$t; done

  if [ "$TIER" -le 16 ]; then
    info "${C}16 GB Apple Silicon Architecture Note:${N}"
    info "Hermes Agent requires a 64K context window for multi-step tool calling."
    info "Safe model ceiling: ${MAX_SAFE_RSS_GB} GB (reserving ${SYSTEM_RESERVE_GB} GB for macOS)."
    info "Compact models (Hermes 3 3B, Qwen3 4B) are curated to operate within these bounds."
  elif [ "$TIER" -ge 36 ]; then
    info "${C}High-Capacity Architecture Note:${N}"
    info "With ${RAM_GB} GB memory (${MAX_SAFE_RSS_GB} GB model budget), 30B-35B MoE models run with full 64K context."
  fi

  info "Checking what is currently downloadable…"
  local n=0 row; CHOICES=""
  while IFS= read -r row; do
    [ -z "$row" ] && continue
    [ "$(echo "$row" | cut -d'|' -f1)" = "$TIER" ] || continue
    if exists_online "$row"; then n=$((n+1)); CHOICES="$CHOICES$row"$'\n'
      echo "    ${B}$n)${N} $(echo "$row" | cut -d'|' -f2)   ${C}[$(echo "$row" | cut -d'|' -f5)]${N}"
    fi
  done <<EOF
$CATALOGUE
EOF
  [ $n -eq 0 ] && die "Couldn't reach Hugging Face / Ollama to check models. Is the internet working?"

  if [ "$BACKEND" = lmstudio ]; then   # show what is trending — informational only
    info "${C}Newest popular MLX builds on Hugging Face (FYI):${N}"
    curl -s "https://huggingface.co/api/models?author=mlx-community&filter=text-generation&sort=trendingScore&limit=5" \
      | python3 -c "import sys,json
try:
    [print('      ·',m['id']) for m in json.load(sys.stdin)]
except Exception: pass"
  fi

  local pick=1
  if [ "${HERMES_MODEL_OVERRIDE:-}" != "" ]; then
    MODEL_TAG="$HERMES_MODEL_OVERRIDE"; MODEL_REPO="$HERMES_MODEL_OVERRIDE"; MODEL_LABEL="$HERMES_MODEL_OVERRIDE"
  else
    [ $n -gt 1 ] && { pick="$(ask "Type a number, or just press Return for 1:")"; pick="${pick:-1}"; }
    row="$(echo "$CHOICES" | sed -n "${pick}p")"; [ -z "$row" ] && row="$(echo "$CHOICES" | sed -n 1p)"
    MODEL_LABEL="$(echo "$row" | cut -d'|' -f2)"
    MODEL_TAG="$(echo "$row" | cut -d'|' -f3)"
    MODEL_REPO="$(echo "$row" | cut -d'|' -f4)"
  fi
  ok "Selected: $MODEL_LABEL"
}

# ------------------------------------------------------- 3 install + tune it --
tune_ollama() {
  step "Step 3 · Downloading and tuning the model (Ollama)"
  BASE_URL="http://localhost:11434/v1"
  # The Ollama *app* ignores shell exports; it only sees launchctl variables.
  launchctl setenv OLLAMA_FLASH_ATTENTION 1        # big speed-up at long context
  launchctl setenv OLLAMA_KV_CACHE_TYPE q8_0       # halves the memory a 64K context needs
  launchctl setenv OLLAMA_CONTEXT_LENGTH $CTX
  launchctl setenv OLLAMA_KEEP_ALIVE 24h           # don't unload between Slack messages
  launchctl setenv OLLAMA_NUM_PARALLEL 1           # 1 user: don't reserve 4x the KV cache
  launchctl setenv OLLAMA_MAX_LOADED_MODELS 1

  # Re-apply the same variables at every login.
  local plist="$HOME/Library/LaunchAgents/com.hermes-easy.ollama-env.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.hermes-easy.ollama-env</string>
  <key>RunAtLoad</key><true/>
  <key>ProgramArguments</key><array><string>/bin/sh</string><string>-c</string>
  <string>launchctl setenv OLLAMA_FLASH_ATTENTION 1; launchctl setenv OLLAMA_KV_CACHE_TYPE q8_0; launchctl setenv OLLAMA_CONTEXT_LENGTH $CTX; launchctl setenv OLLAMA_KEEP_ALIVE 24h; launchctl setenv OLLAMA_NUM_PARALLEL 1; launchctl setenv OLLAMA_MAX_LOADED_MODELS 1</string></array>
</dict></plist>
EOF
  launchctl unload "$plist" 2>/dev/null; launchctl load "$plist" 2>/dev/null
  ok "Speed settings saved (flash attention, 8-bit KV cache, 64K context, keep-loaded)"

  info "Restarting Ollama so it picks the settings up…"
  osascript -e 'quit app "Ollama"' 2>/dev/null; pkill -x ollama 2>/dev/null; sleep 2
  open -a Ollama 2>/dev/null || (nohup ollama serve >>"$LOG" 2>&1 &)
  local i=0; until curl -s localhost:11434/api/version >/dev/null; do sleep 1; i=$((i+1)); [ $i -gt 40 ] && die "Ollama didn't start."; done
  ok "Ollama is running"

  info "Downloading $MODEL_TAG — this is the long part (10–40 min). Leave it running."
  ollama pull "$MODEL_TAG" || die "Download failed."
  # Bake the context size into a named copy so it holds even if the env vars get lost.
  local mf; mf="$(mktemp)"
  printf 'FROM %s\nPARAMETER num_ctx %s\n' "$MODEL_TAG" "$CTX" > "$mf"
  ollama create "$LOCAL_ID" -f "$mf" >>"$LOG" 2>&1 || die "Couldn't create the tuned model."
  ok "Tuned model '${LOCAL_ID}' created"
}

tune_lmstudio() {
  step "Step 3 · Downloading and tuning the model (LM Studio / MLX)"
  BASE_URL="http://localhost:1234/v1"
  have lms || {
    [ -x "$HOME/.cache/lm-studio/bin/lms" ] && export PATH="$HOME/.cache/lm-studio/bin:$PATH"
    [ -x "$HOME/.lmstudio/bin/lms" ] && export PATH="$HOME/.lmstudio/bin:$PATH"
  }
  have lms || "$HOME/.lmstudio/bin/lms" bootstrap >>"$LOG" 2>&1
  have lms || "$HOME/.cache/lm-studio/bin/lms" bootstrap >>"$LOG" 2>&1
  have lms || die "LM Studio's command-line helper (lms) isn't available."
  lms server start >>"$LOG" 2>&1

  # Ensure MLX runtime extension is installed and selected on Apple Silicon
  if [ "$ARCH" = "arm64" ]; then
    if ! lms runtime ls 2>/dev/null | grep -q "mlx-llm"; then
      info "Installing LM Studio's Apple Silicon MLX runtime extension…"
      lms runtime get mlx-llm --yes >>"$LOG" 2>&1 || warn "Could not pre-install mlx-llm extension; continuing."
    fi
    local mlx_ver
    mlx_ver="$(lms runtime ls 2>/dev/null | awk '/mlx-llm/{print $1; exit}')"
    if [ -n "$mlx_ver" ]; then
      lms runtime select "$mlx_ver" >>"$LOG" 2>&1 || true
      ok "LM Studio MLX engine selected: $mlx_ver"
    fi
  fi

  local hf_url="$MODEL_REPO"
  case "$hf_url" in
    https://*|http://*) ;;
    *) hf_url="https://huggingface.co/$MODEL_REPO";;
  esac

  info "Downloading $MODEL_REPO — this can take 10–30 min depending on network speed. Leave it running."
  # LM Studio CLI resolves Hugging Face models via full URL; fallback to repo name or staff picks
  lms get "$hf_url" --yes || lms get "$MODEL_REPO" --yes || lms get "$MODEL_REPO" --mlx --yes || die "Download failed."
  lms unload --all >>"$LOG" 2>&1

  # Resolve the exact model key assigned by LM Studio on disk
  local base base_stem lms_key
  base="$(basename "$MODEL_REPO" | tr 'A-Z' 'a-z')"
  base_stem="${base%%-4bit}"
  base_stem="${base_stem%%-8bit}"
  lms_key="$(lms ls 2>/dev/null | awk -v stem="$base_stem" 'NR>4 && $1 ~ stem {print $1; exit}')"
  [ -z "$lms_key" ] && lms_key="$(lms ls 2>/dev/null | awk -v b="$base" 'NR>4 && $1 ~ b {print $1; exit}')"
  [ -z "$lms_key" ] && lms_key="$MODEL_REPO"

  # Dynamic GPU offload determination:
  # Never force --gpu max blindly! On constrained machines, let LM Studio auto-balance
  # to keep resident memory below the safe ceiling (${MAX_SAFE_RSS_GB} GB).
  local gpu_opt=""
  if [ "$RAM_GB" -ge 48 ]; then
    gpu_opt="--gpu max"
  elif [ "$RAM_GB" -ge 32 ]; then
    gpu_opt="--gpu 0.85"
  else
    # On 16-24 GB, omit --gpu to allow LM Studio engine auto-balancing
    gpu_opt=""
  fi

  info "Checking resource guardrails for $lms_key at 64K context…"
  local estimate_out
  estimate_out="$(lms load "$lms_key" --context-length $CTX $gpu_opt --estimate-only 2>&1 || true)"
  echo "$estimate_out" >> "$LOG"
  if echo "$estimate_out" | grep -qi "fail to load based on your resource guardrails"; then
    warn "LM Studio resource guardrails warned that $lms_key with 64K context is tight on ${RAM_GB} GB RAM."
    info "Using auto-balanced GPU offload with Canary Watchdog surveillance."
    gpu_opt=""
  fi

  info "Loading $lms_key with 64K context (${gpu_opt:-auto-balanced offload})…"
  lms load "$lms_key" --context-length $CTX $gpu_opt --parallel 1 --identifier "$LOCAL_ID" --yes >>"$LOG" 2>&1 \
    || lms load "$MODEL_REPO" --context-length $CTX $gpu_opt --parallel 1 --identifier "$LOCAL_ID" --yes >>"$LOG" 2>&1 \
    || lms load "$base" --context-length $CTX $gpu_opt --parallel 1 --identifier "$LOCAL_ID" --yes >>"$LOG" 2>&1 \
    || die "Model downloaded but wouldn't load. See $LOG"
  ok "Model loaded with 64K context (${gpu_opt:-auto-balanced}) as '${LOCAL_ID}'"

  # Reload it the same way at every login (LM Studio's auto-load would use default settings).
  local sh="$HERMES_HOME/start-local-model.sh" plist="$HOME/Library/LaunchAgents/com.hermes-easy.lmstudio.plist"
  cat > "$sh" <<EOF
#!/bin/bash
export PATH="\$HOME/.cache/lm-studio/bin:\$HOME/.lmstudio/bin:/opt/homebrew/bin:/usr/local/bin:\$PATH"
sleep 20
lms server start
lms ps | grep -q "$LOCAL_ID" || lms load "$lms_key" --context-length $CTX $gpu_opt --parallel 1 --identifier "$LOCAL_ID" --yes
EOF
  chmod +x "$sh"; mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.hermes-easy.lmstudio</string>
  <key>RunAtLoad</key><true/>
  <key>ProgramArguments</key><array><string>$sh</string></array>
</dict></plist>
EOF
  launchctl unload "$plist" 2>/dev/null; launchctl load "$plist" 2>/dev/null
  ok "Model will reload automatically with safe offload profile after a restart"
}

benchmark() {
  step "Step 4 · Canary verification & speed test"
  local port=1234
  [ "${BACKEND:-}" = ollama ] && port=11434

  info "Starting Canary Memory Watchdog (safe ceiling: ${MAX_SAFE_RSS_GB} GB resident memory)…"
  watchdog_start "$port" "$MAX_SAFE_RSS_KB"

  local body='{"model":"'"$LOCAL_ID"'","max_tokens":200,"messages":[{"role":"user","content":"Count from 1 to 60, numbers only."}]}'
  info "Warming up with canary prompt (active memory surveillance enabled)…"
  local curl_err=0
  curl -s -m 120 "$BASE_URL/chat/completions" -H 'Content-Type: application/json' -d "$body" >/dev/null || curl_err=$?

  if [ -f "$WATCHDOG_FLAG" ]; then
    watchdog_stop
    local breach_rss; breach_rss="$(cat "$WATCHDOG_FLAG")"
    local breach_gb; breach_gb=$(python3 -c "print(round($breach_rss/1048576, 1))")
    bad "Canary Watchdog TRIPPED: Server memory hit ${breach_gb} GB (safe ceiling: ${MAX_SAFE_RSS_GB} GB)!"
    warn "The model was immediately unloaded to prevent a macOS kernel panic."

    if [ "${BACKEND:-}" = lmstudio ]; then
      info "LM Studio's unquantized KV cache exceeded safe unified memory bounds."
      if have ollama || [ -d "/Applications/Ollama.app" ]; then
        info "Auto-remediating: Switching to Ollama (uses 8-bit quantized KV cache and Flash Attention on Metal)…"
        BACKEND=ollama
        tune_ollama
        benchmark
        return $?
      else
        die "Memory ceiling exceeded. Quit other applications or install Ollama for 8-bit quantized KV caching."
      fi
    else
      die "Memory ceiling exceeded under Ollama. Quit background applications and run: bash $0 model"
    fi
  fi

  watchdog_stop
  [ $curl_err -ne 0 ] && { bad "The model server failed to answer or timed out at $BASE_URL"; return 1; }

  # Timed token generation test under watchdog surveillance
  watchdog_start "$port" "$MAX_SAFE_RSS_KB"
  local t0 t1 toks; t0=$(python3 -c 'import time;print(time.time())')
  toks="$(curl -s -m 120 "$BASE_URL/chat/completions" -H 'Content-Type: application/json' -d "$body" | json "d['usage']['completion_tokens']")"
  t1=$(python3 -c 'import time;print(time.time())')

  if [ -f "$WATCHDOG_FLAG" ]; then
    watchdog_stop
    bad "Canary Watchdog TRIPPED during generation! Model was unloaded for safety."
    return 1
  fi
  watchdog_stop

  [ -z "$toks" ] && { bad "The model server didn't answer at $BASE_URL"; return 1; }
  TPS=$(python3 -c "print(round($toks/($t1-$t0)))")
  if [ "$TPS" -ge 25 ]; then ok "${TPS} tokens/second — verified stable and fast under memory ceiling."
  elif [ "$TPS" -ge 10 ]; then warn "${TPS} tokens/second — usable and stable within safe memory bounds."
  else bad "${TPS} tokens/second — too slow. Quit memory-hungry apps and run:  bash $0 model"; fi
}

# ---------------------------------------------------------- 5 hermes itself --
install_hermes() {
  step "Step 5 · Installing Hermes Agent"
  if have hermes; then ok "Hermes already installed"
  else
    info "Running the official Hermes installer…"
    # --skip-setup: without it the installer launches Hermes's own wizard (provider picker) on /dev/tty.
    curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --skip-setup || die "Hermes installer failed."
    export PATH="$HOME/.local/bin:$PATH"
    have hermes || die "Hermes installed but the 'hermes' command isn't on the PATH."
    ok "Hermes installed"
  fi
  [ -f "$HERMES_HOME/config.yaml" ] && [ ! -f "$HERMES_HOME/config.yaml.before-easy-setup" ] && cp "$HERMES_HOME/config.yaml" "$HERMES_HOME/config.yaml.before-easy-setup"
  # Provider must be set first: switching provider clears the old provider's base_url.
  if [ "$BACKEND" = lmstudio ]; then
    hermes config set model.provider lmstudio         >>"$LOG" 2>&1
  else
    hermes config set model.provider custom           >>"$LOG" 2>&1
    hermes config set model.ollama_num_ctx $CTX       >>"$LOG" 2>&1   # Hermes sends this num_ctx on every Ollama request
  fi
  hermes config set model.base_url "$BASE_URL"      >>"$LOG" 2>&1
  hermes config set model.default "$LOCAL_ID"       >>"$LOG" 2>&1
  hermes config set model.context_length $CTX       >>"$LOG" 2>&1
  # Local inference optimizations: avoid concurrent auxiliary tasks that lock single-slot local runners
  hermes config set auxiliary.title_generation.enabled false    >>"$LOG" 2>&1 || true
  hermes config set auxiliary.background_review.enabled false   >>"$LOG" 2>&1 || true
  hermes config set slack.require_mention false                 >>"$LOG" 2>&1 || true
  set_env HERMES_API_TIMEOUT 1800
  grep -q "$LOCAL_ID" "$HERMES_HOME/config.yaml" 2>/dev/null || die "Hermes config wasn't updated — see $LOG"
  ok "Hermes pointed at $LOCAL_ID ($BASE_URL, 64K context, local optimizations applied)"
}

# ------------------------------------------------------------------ 6 slack --
validate_bot_token() { # sets BOT_USER TEAM_NAME; returns 1 on failure
  local out; out="$(slack_api "$1" auth.test)"
  if [ "$(echo "$out" | json "d['ok']")" != "True" ]; then
    bad "Slack rejected that token: $(echo "$out" | json "d.get('error')")"; return 1; fi
  TEAM_NAME="$(echo "$out" | json "d['team']")"; BOT_USER="$(echo "$out" | json "d['user']")"
  ok "Bot token works — bot '${BOT_USER}' in workspace '${TEAM_NAME}'"
  local granted missing=""; granted="$(grep -i '^x-oauth-scopes:' "$HDRS" 2>/dev/null | cut -d: -f2- | tr -d ' \r')"
  if [ -z "$granted" ]; then warn "Couldn't read the permission list from Slack — skipping that check."; return 0; fi
  for s in $REQUIRED_SCOPES; do echo ",$granted," | grep -q ",$s," || missing="$missing $s"; done
  if [ -n "$missing" ]; then
    bad "The app is missing permissions:$missing"
    info "This means the manifest wasn't used, or the app wasn't reinstalled after a change."
    return 1
  fi
  ok "All ${B}14${N} required permissions are present"
}

validate_app_token() {
  local out; out="$(slack_api "$1" apps.connections.open)"
  if [ "$(echo "$out" | json "d['ok']")" = "True" ]; then ok "App token works and Socket Mode is on"; return 0; fi
  local e; e="$(echo "$out" | json "d.get('error')")"
  bad "Slack rejected the app token: $e"
  case "$e" in
    *not_allowed_token*|*invalid_auth*) info "Make sure you copied the token that starts with xapp- from 'App-Level Tokens'.";;
    *missing_scope*) info "The app-level token needs the 'connections:write' scope. Delete it and generate a new one.";;
  esac
  return 1
}

slack_cli_capture() { # EXPERIMENTAL: let the Slack CLI create+install the app and hand us both tokens
  have slack || { info "Installing the Slack command-line tool…"
                  curl -fsSL https://downloads.slack-edge.com/slack-cli/install.sh | bash >>"$LOG" 2>&1
                  export PATH="$HOME/.slack/bin:$PATH"; }
  have slack || return 1
  local proj="$HERMES_HOME/slack-cli-project"; rm -rf "$proj"; mkdir -p "$proj/.slack"
  cat > "$proj/.slack/hooks.json" <<EOF
{ "hooks": { "get-manifest": "cat $MANIFEST", "start": "bash $proj/capture.sh" },
  "config": { "sdk-managed-connection-enabled": true } }
EOF
  echo '{ "manifest": { "source": "local" } }' > "$proj/.slack/config.json"
  cat > "$proj/capture.sh" <<EOF
#!/bin/bash
umask 077
echo "BOT=\${SLACK_BOT_TOKEN:-\$SLACK_CLI_XOXB}"  > "$proj/captured"
echo "APP=\${SLACK_APP_TOKEN:-\$SLACK_CLI_XAPP}" >> "$proj/captured"
EOF
  if ! (cd "$proj" && slack auth list 2>/dev/null | grep -q "User ID"); then
    echo; info "${B}Logging in to Slack.${N} The tool will show a line starting with ${B}/slackauthticket${N}."
    info "1. Copy that whole line   2. Paste it into any Slack channel and press Return"
    info "3. Click ${B}Confirm${N} in Slack   4. Copy the short code Slack shows, paste it back here"
    (cd "$proj" && slack login) || return 1
  fi
  info "Creating and installing the Slack app… choose your workspace if asked."
  (cd "$proj" && slack run --skip-update) >>"$LOG" 2>&1
  [ -f "$proj/captured" ] || return 1
  BOT_TOKEN="$(grep '^BOT=' "$proj/captured" | cut -d= -f2-)"; APP_TOKEN="$(grep '^APP=' "$proj/captured" | cut -d= -f2-)"
  rm -f "$proj/captured"
  case "$BOT_TOKEN" in xoxb-*) ;; *) return 1;; esac
  case "$APP_TOKEN" in xapp-*) ;; *) return 1;; esac
}

slack_workspace_ready() { # the app-creation page only works if the browser is signed in to a workspace
  echo; info "${B}First: a Slack workspace.${N} The bot has to live inside one, and your web browser"
  info "must be signed in to it (being signed in to the Slack ${B}app${N} is not enough)."
  if yesno "Do you already have a Slack workspace you want to use?"; then
    info "A sign-in page will open. Sign in to that workspace ${B}in the browser${N}, then come back here."
    info "(If it shows your workspace already, just click it.)"
    open "https://slack.com/signin"
  else
    info "A page will open to create a free one: enter your email, type the code Slack emails you,"
    info "give the workspace any name (e.g. 'Home'), and skip inviting people / choosing a paid plan."
    open "https://slack.com/get-started#/createnew"
  fi
  pause
}

slack_guided() {
  slack_workspace_ready
  pbcopy < "$MANIFEST"
  echo; info "${B}A) Create the app${N} — the settings are already copied to your clipboard."
  info "   A web page will open. Click:  ${B}From a manifest${N} → pick your workspace → ${B}Next${N}"
  info "   (If your workspace isn't in the list, click ${B}Sign in to another workspace${N}, sign in, then come back to that page.)"
  info "   → click the ${B}JSON${N} tab, select everything in the box, paste (⌘V) → ${B}Next${N} → ${B}Create${N}"
  open "https://api.slack.com/apps?new_app=1"; pause

  info "${B}B) Install it${N} — left sidebar: ${B}Install App${N} → ${B}Install to Workspace${N} → ${B}Allow${N}"
  info "   Then copy the ${B}Bot User OAuth Token${N} (starts with xoxb-)."
  while :; do
    BOT_TOKEN="$(trim "$(ask "Paste the xoxb- token here:")")"
    case "$BOT_TOKEN" in xoxb-*) validate_bot_token "$BOT_TOKEN" && break;;
      xapp-*) bad "That's the App token (xapp-). I need the Bot token (xoxb-) from 'Install App'.";;
      *) bad "That doesn't start with xoxb- — copy it again with the Copy button.";; esac
  done

  echo; info "${B}C) App token${N} — left sidebar: ${B}Basic Information${N} → scroll to ${B}App-Level Tokens${N}"
  info "   → ${B}Generate Token and Scopes${N} → name it 'hermes' → ${B}Add Scope${N} → ${B}connections:write${N} → ${B}Generate${N}"
  while :; do
    APP_TOKEN="$(trim "$(ask "Paste the xapp- token here:")")"
    case "$APP_TOKEN" in xapp-*) validate_app_token "$APP_TOKEN" && break;;
      *) bad "That doesn't start with xapp-.";; esac
  done
}

pick_allowed_user() {
  local out; out="$(slack_api "$BOT_TOKEN" users.list)"
  echo "$out" | python3 -c "import sys,json
m=[u for u in json.load(sys.stdin).get('members',[]) if not u.get('is_bot') and not u.get('deleted') and u['id']!='USLACKBOT']
[print('    %d) %s'%(i+1,u.get('real_name') or u['name'])) for i,u in enumerate(m)]
open('$HERMES_HOME/.members','w').write('\n'.join(u['id'] for u in m))"
  local n; n="$(ask "Which one is you? Type the number:")"
  ALLOWED_USER="$(sed -n "${n:-1}p" "$HERMES_HOME/.members")"; rm -f "$HERMES_HOME/.members"
  [ -n "$ALLOWED_USER" ] || die "Couldn't work out your Slack member ID."
  ok "Only you ($ALLOWED_USER) will be allowed to talk to the bot"
}

setup_slack() {
  step "Step 6 · Connecting Slack"
  have hermes || die "Hermes isn't installed yet — run the full setup first."
  hermes slack manifest --agent-view --write >>"$LOG" 2>&1
  [ -s "$MANIFEST" ] || die "Hermes didn't produce $MANIFEST"
  python3 -c "import json;json.load(open('$MANIFEST'))" 2>/dev/null || die "The Slack manifest isn't valid JSON."
  ok "Slack app settings generated"

  BOT_TOKEN="$(get_env SLACK_BOT_TOKEN)"; APP_TOKEN="$(get_env SLACK_APP_TOKEN)"
  if [ -n "$BOT_TOKEN" ] && [ -n "$APP_TOKEN" ] && validate_bot_token "$BOT_TOKEN" && validate_app_token "$APP_TOKEN"; then
    ok "Existing Slack connection is healthy — keeping it"
  else
    if [ "${HERMES_SLACK_AUTO:-0}" = 1 ] && slack_cli_capture && validate_bot_token "$BOT_TOKEN" && validate_app_token "$APP_TOKEN"; then
      ok "Slack app created and installed automatically"
    else
      [ "${HERMES_SLACK_AUTO:-0}" = 1 ] && warn "Automatic route didn't work — switching to the guided route."
      slack_guided
    fi
    set_env SLACK_BOT_TOKEN "$BOT_TOKEN"; set_env SLACK_APP_TOKEN "$APP_TOKEN"
  fi
  [ -n "$(get_env SLACK_ALLOWED_USERS)" ] || { pick_allowed_user; set_env SLACK_ALLOWED_USERS "$ALLOWED_USER"; }
  ALLOWED_USER="$(get_env SLACK_ALLOWED_USERS | cut -d, -f1)"

  info "Starting Hermes in the background…"
  hermes gateway install >>"$LOG" 2>&1 || true
  hermes gateway restart >>"$LOG" 2>&1 || hermes gateway start >>"$LOG" 2>&1 || warn "Couldn't start the background service — see $LOG"
  sleep 5
  local ch; ch="$(slack_api "$BOT_TOKEN" conversations.open -d "users=$ALLOWED_USER" | json "d['channel']['id']")"
  if [ -n "$ch" ] && [ "$(slack_api "$BOT_TOKEN" chat.postMessage -d "channel=$ch" --data-urlencode "text=👋 Setup finished. Reply to this message to talk to Hermes." | json "d['ok']")" = "True" ]; then
    ok "Test message sent — look for a DM from the bot in Slack and reply to it"
  else
    warn "Couldn't send a test DM. In Slack: Apps → find the bot → send it a message."
  fi
}

# ----------------------------------------------------------------- doctor ---
doctor() {
  step "Doctor · checking everything (nothing will be changed)"
  info "Memory bounds: ${RAM_GB} GB physical RAM (Safe model budget: ${MAX_SAFE_RSS_GB} GB, OS reserve: ${SYSTEM_RESERVE_GB} GB)"
  have hermes && ok "hermes command found" || bad "hermes not installed"
  if curl -s -m 3 localhost:1234/v1/models | grep -q "$LOCAL_ID"; then
    ok "LM Studio is serving $LOCAL_ID"; BACKEND=lmstudio; BASE_URL="http://localhost:1234/v1"
    if have lms; then
      info "LM Studio active models:"
      lms ps 2>/dev/null | awk 'NR>1 {print "    · " $0}'
    fi
  elif curl -s -m 3 localhost:11434/api/tags | grep -q "$LOCAL_ID"; then
    ok "Ollama has $LOCAL_ID"; BACKEND=ollama; BASE_URL="http://localhost:11434/v1"
    [ "$(launchctl getenv OLLAMA_FLASH_ATTENTION)" = 1 ] && ok "Ollama speed settings active" || bad "Ollama speed settings missing — run: bash $0 model"
    ollama ps 2>/dev/null | awk 'NR>1 && /CPU/ {print "  \033[31m✘\033[0m model is partly running on CPU (out of GPU memory): " $0}'
  else
    bad "No model server is serving '$LOCAL_ID' — run: bash $0 model"
  fi
  [ -n "${BASE_URL:-}" ] && benchmark
  local b a; b="$(get_env SLACK_BOT_TOKEN)"; a="$(get_env SLACK_APP_TOKEN)"
  [ -n "$b" ] && validate_bot_token "$b" || bad "No working Slack bot token"
  [ -n "$a" ] && validate_app_token "$a" || bad "No working Slack app token"
  [ -n "$(get_env SLACK_ALLOWED_USERS)" ] && ok "Allowed user set" || bad "SLACK_ALLOWED_USERS is empty — the bot will ignore everyone"
  have hermes && { hermes gateway status 2>&1 | tail -3; hermes doctor 2>&1 | tail -15; }
}

# -------------------------------------------------------------------- main --
preflight
case "${1:-all}" in
  doctor) doctor;;
  model)  detect_backend; pick_model; if [ "$BACKEND" = ollama ]; then tune_ollama; else tune_lmstudio; fi; benchmark; install_hermes;;
  slack)  setup_slack;;
  all)    detect_backend; pick_model; if [ "$BACKEND" = ollama ]; then tune_ollama; else tune_lmstudio; fi
          benchmark; install_hermes; setup_slack
          step "All done 🎉"; info "If anything stops working later, run:  ${B}bash $0 doctor${N}";;
  *) echo "Usage: bash $0 [all|model|slack|doctor]";;
esac
