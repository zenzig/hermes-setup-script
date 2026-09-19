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

# Model catalogue:  min_ram_gb | label | ollama_tag | mlx_repo | why
# Ordered best-first inside each RAM tier. MoE models (A3B/A4B) only touch ~3-4B
# parameters per token, so they are several times faster than a dense model of
# the same quality on Apple Silicon — that is why they lead the list.
CATALOGUE='
36|Qwen3.6 35B-A3B (best tool use, fast MoE)|qwen3.6:35b|mlx-community/Qwen3.6-35B-A3B-4bit|recommended
36|Qwen3-Coder 30B-A3B (no "thinking" pause, snappiest replies)|qwen3-coder:30b|mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit|fastest
36|Gemma 4 26B-A4B (fast MoE, good writing)|gemma4:26b|mlx-community/gemma-4-26b-a4b-it-4bit|alternative
24|GPT-OSS 20B (fast MoE, 13 GB)|gpt-oss:20b|mlx-community/gpt-oss-20b-MXFP4-Q8|recommended
16|Qwen3 4B (leaves room for the 64K context)|qwen3:4b|mlx-community/Qwen3-4B-Instruct-2507-4bit|recommended
16|Qwen3 8B (smarter, but very tight on 16 GB)|qwen3:8b|mlx-community/Qwen3-8B-4bit|alternative
8|Qwen3 4B (small, basic tool use only)|qwen3:4b|mlx-community/Qwen3-4B-Instruct-2507-4bit|recommended
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

# --------------------------------------------------------------- 0 preflight --
preflight() {
  step "Step 0 · Checking this Mac"
  [ "$(uname -s)" = "Darwin" ] || die "This script is for macOS."
  mkdir -p "$HERMES_HOME"; : >> "$LOG"
  export PATH="$HOME/.local/bin:$HOME/.lmstudio/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

  if ! xcode-select -p >/dev/null 2>&1; then
    warn "Apple's developer tools are needed (one-time, free, ~5 min)."
    info "A window will pop up — click ${B}Install${N}, wait for it to finish."
    xcode-select --install >/dev/null 2>&1
    until xcode-select -p >/dev/null 2>&1; do sleep 10; printf "."; done; echo
  fi
  ok "Developer tools present"

  ARCH="$(uname -m)"
  CHIP="$(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
  RAM_GB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
  DISK_GB=$(df -g "$HOME" | awk 'NR==2{print $4}')
  ok "$CHIP · ${RAM_GB} GB memory · ${DISK_GB} GB free disk"
  [ "$DISK_GB" -lt 30 ] && warn "Less than 30 GB free — a model download may not fit."
}

# ------------------------------------------------------------ 1 pick backend --
detect_backend() {
  step "Step 1 · Finding your local AI engine"
  HAS_LMS=0; HAS_OLLAMA=0
  if have lms || [ -x "$HOME/.lmstudio/bin/lms" ]; then HAS_LMS=1; fi
  [ $HAS_LMS -eq 0 ] && [ -d "/Applications/LM Studio.app" ] && HAS_LMS=2   # installed, never opened
  if have ollama || [ -d "/Applications/Ollama.app" ]; then HAS_OLLAMA=1; fi
  [ $HAS_OLLAMA -eq 1 ] && ! have ollama && export PATH="/Applications/Ollama.app/Contents/Resources:$PATH"

  if [ $HAS_LMS -eq 2 ]; then
    warn "LM Studio is installed but has never been opened. Opening it now…"
    open -a "LM Studio"; info "Wait for its window to appear, skip any welcome screens."
    pause
    [ -x "$HOME/.lmstudio/bin/lms" ] && HAS_LMS=1 || HAS_LMS=0
  fi
  [ $HAS_LMS -eq 1 ]    && ok "LM Studio found"
  [ $HAS_OLLAMA -eq 1 ] && ok "Ollama found"

  if [ "${HERMES_BACKEND:-}" != "" ]; then BACKEND="$HERMES_BACKEND"
  elif [ "$RAM_GB" -lt 24 ] && [ $HAS_OLLAMA -eq 1 ]; then BACKEND=ollama   # needs Ollama's 8-bit KV cache to fit 64K
  elif [ "$ARCH" = "arm64" ] && [ $HAS_LMS -eq 1 ]; then BACKEND=lmstudio
  elif [ $HAS_OLLAMA -eq 1 ]; then BACKEND=ollama
  elif [ $HAS_LMS -eq 1 ]; then BACKEND=lmstudio
  else
    warn "Neither Ollama nor LM Studio is installed. Opening the Ollama download page."
    info "Download it, drag it to Applications, open it once, then come back here."
    open "https://ollama.com/download"; pause
    export PATH="/Applications/Ollama.app/Contents/Resources:$PATH"
    have ollama || die "Still can't find Ollama."
    BACKEND=ollama
  fi
  if [ "$BACKEND" = lmstudio ]; then
    ok "Using ${B}LM Studio${N} — its MLX engine is the fastest option on Apple Silicon"
    BASE_URL="http://localhost:1234/v1"
  else
    ok "Using ${B}Ollama${N}"
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
  have lms || "$HOME/.lmstudio/bin/lms" bootstrap >>"$LOG" 2>&1
  have lms || die "LM Studio's command-line helper (lms) isn't available."
  lms server start >>"$LOG" 2>&1
  info "Downloading $MODEL_REPO — this is the long part (10–40 min). Leave it running."
  lms get "$MODEL_REPO" --mlx --yes || lms get "$MODEL_REPO" --yes || die "Download failed."
  lms unload --all >>"$LOG" 2>&1
  lms load "$MODEL_REPO" --context-length $CTX --gpu max --identifier "$LOCAL_ID" --yes >>"$LOG" 2>&1 \
    || lms load "$(basename "$MODEL_REPO" | tr 'A-Z' 'a-z')" --context-length $CTX --gpu max --identifier "$LOCAL_ID" --yes >>"$LOG" 2>&1 \
    || die "Model downloaded but wouldn't load. See $LOG"
  ok "Model loaded with 64K context, fully on the GPU, as '${LOCAL_ID}'"

  # Reload it the same way at every login (LM Studio's auto-load would use default settings).
  local sh="$HERMES_HOME/start-local-model.sh" plist="$HOME/Library/LaunchAgents/com.hermes-easy.lmstudio.plist"
  cat > "$sh" <<EOF
#!/bin/bash
export PATH="\$HOME/.lmstudio/bin:\$PATH"
sleep 20
lms server start
lms ps | grep -q "$LOCAL_ID" || lms load "$MODEL_REPO" --context-length $CTX --gpu max --identifier "$LOCAL_ID" --yes
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
  ok "Model will reload automatically after a restart"
}

benchmark() {
  step "Step 4 · Speed test"
  local body='{"model":"'"$LOCAL_ID"'","max_tokens":200,"messages":[{"role":"user","content":"Count from 1 to 60, numbers only."}]}'
  info "Warming up (first load can take a minute)…"
  curl -s -m 600 "$BASE_URL/chat/completions" -H 'Content-Type: application/json' -d "$body" >/dev/null
  local t0 t1 toks; t0=$(python3 -c 'import time;print(time.time())')
  toks="$(curl -s -m 600 "$BASE_URL/chat/completions" -H 'Content-Type: application/json' -d "$body" | json "d['usage']['completion_tokens']")"
  t1=$(python3 -c 'import time;print(time.time())')
  [ -z "$toks" ] && { bad "The model server didn't answer at $BASE_URL"; return 1; }
  TPS=$(python3 -c "print(round($toks/($t1-$t0)))")
  if [ "$TPS" -ge 25 ]; then ok "${TPS} tokens/second — that's fast."
  elif [ "$TPS" -ge 10 ]; then warn "${TPS} tokens/second — usable. Closing other apps will help."
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
  set_env HERMES_API_TIMEOUT 1800
  grep -q "$LOCAL_ID" "$HERMES_HOME/config.yaml" 2>/dev/null || die "Hermes config wasn't updated — see $LOG"
  ok "Hermes pointed at $LOCAL_ID ($BASE_URL, 64K context)"
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
  hermes gateway install >>"$LOG" 2>&1 || warn "Couldn't install the background service — see $LOG"
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
  have hermes && ok "hermes command found" || bad "hermes not installed"
  if curl -s -m 3 localhost:1234/v1/models | grep -q "$LOCAL_ID"; then ok "LM Studio is serving $LOCAL_ID"; BASE_URL="http://localhost:1234/v1"
  elif curl -s -m 3 localhost:11434/api/tags | grep -q "$LOCAL_ID"; then ok "Ollama has $LOCAL_ID"; BASE_URL="http://localhost:11434/v1"
    [ "$(launchctl getenv OLLAMA_FLASH_ATTENTION)" = 1 ] && ok "Ollama speed settings active" || bad "Ollama speed settings missing — run: bash $0 model"
    ollama ps 2>/dev/null | awk 'NR>1 && /CPU/ {print "  \033[31m✘\033[0m model is partly running on CPU (out of GPU memory): " $0}'
  else bad "No model server is serving '$LOCAL_ID' — run: bash $0 model"; fi
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
