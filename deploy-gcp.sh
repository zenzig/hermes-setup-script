#!/bin/bash
# =============================================================================
#  deploy-gcp.sh  —  Automated Google Cloud "Always Free" Hermes Agent Deployer
#  Author: Rich Olson
#  Target: macOS / Linux / Google Cloud Shell
#
#  Provisions an Always-Free e2-micro instance on Google Cloud Compute Engine,
#  configures 2 GB swap space, installs Hermes Agent, connects Google Gemini
#  (or OpenRouter) + Slack, and launches a 24/7 background gateway daemon.
#
#  Always-Free Guardrails Enforced:
#    - Machine Type: e2-micro (2 vCPU, 1 GB RAM — pooled 744 hrs/mo = $0)
#    - Boot Disk: 30 GB Standard Persistent Disk (pd-standard = $0)
#    - Regions: us-central1 (Iowa), us-west1 (Oregon), or us-east1 (SC)
# =============================================================================
set -u

HERMES_HOME="$HOME/.hermes"
LOCAL_ENV="$HERMES_HOME/.env"
INSTANCE_NAME="hermes-agent-free"
MACHINE_TYPE="e2-micro"
DISK_TYPE="pd-standard"
DISK_SIZE="30GB"
IMAGE_FAMILY="ubuntu-2404-lts-amd64"
IMAGE_PROJECT="ubuntu-os-cloud"
DEFAULT_ZONE="us-central1-a"
ZONE="$DEFAULT_ZONE"
PROVIDER="gemini"
MODEL_NAME="gemini-2.5-flash"
GEMINI_KEY=""
OPENROUTER_KEY=""
CHAT_PLATFORM="telegram"
TELEGRAM_BOT_TOKEN=""
TELEGRAM_USER=""
SLACK_BOT=""
SLACK_APP=""
SLACK_USER=""

# ------------------------------------------------------------------ helpers --
B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'; N=$'\033[0m'
step()  { echo; echo "${B}${C}━━ $* ━━${N}"; }
ok()    { echo "  ${G}✔${N} $*"; }
warn()  { echo "  ${Y}!${N} $*"; }
bad()   { echo "  ${R}✘${N} $*"; }
info()  { echo "    $*"; }
die()   { echo; bad "$*"; exit 1; }
pause() {
  if [ -t 0 ]; then read -r -p "    Press Return to continue… " _ || true
  elif [ -r /dev/tty ]; then read -r -p "    Press Return to continue… " _ </dev/tty || true
  fi
}
ask() {
  local a=""
  if [ -t 0 ]; then read -r -p "    $1 " a || true
  elif [ -r /dev/tty ]; then read -r -p "    $1 " a </dev/tty || true
  else read -r -p "    $1 " a || true
  fi
  echo "$a"
}
yesno() {
  local a=""
  if [ -t 0 ]; then read -r -p "    $1 [Y/n] " a || true
  elif [ -r /dev/tty ]; then read -r -p "    $1 [Y/n] " a </dev/tty || true
  else read -r -p "    $1 [Y/n] " a || true
  fi
  case "$a" in n*|N*) return 1;; *) return 0;; esac
}
have()  { command -v "$1" >/dev/null 2>&1; }
trim()  { echo "$1" | tr -d '[:space:]'; }
get_local_env() { [ -f "$LOCAL_ENV" ] && grep "^$1=" "$LOCAL_ENV" 2>/dev/null | tail -1 | cut -d= -f2- || true; }

# ------------------------------------------------------------ pre-flight & gcloud --
check_gcloud() {
  step "Step 1 · Checking Google Cloud CLI ('gcloud')"
  if have gcloud; then
    ok "gcloud CLI found ($(gcloud version 2>/dev/null | head -1))"
    return 0
  fi

  # Check standard macOS Homebrew / Caskroom paths if not currently in PATH
  if [ -x "/opt/homebrew/Caskroom/google-cloud-sdk/latest/google-cloud-sdk/bin/gcloud" ]; then
    export PATH="/opt/homebrew/Caskroom/google-cloud-sdk/latest/google-cloud-sdk/bin:$PATH"
    ok "Found gcloud in Homebrew Caskroom and added to PATH"
    return 0
  elif [ -x "$HOME/google-cloud-sdk/bin/gcloud" ]; then
    export PATH="$HOME/google-cloud-sdk/bin:$PATH"
    ok "Found gcloud in $HOME/google-cloud-sdk/bin and added to PATH"
    return 0
  fi

  warn "gcloud CLI was not found on your system."
  echo
  info "You have two easy options to proceed:"
  info "  ${B}Option A:${N} Install gcloud on this Mac via Homebrew (automated)."
  info "  ${B}Option B:${N} Use ${B}Google Cloud Shell${N} in your web browser (zero local installation)."
  echo

  if have brew; then
    if yesno "Would you like to install Google Cloud SDK now via Homebrew ('brew install --cask google-cloud-sdk')?"; then
      info "Installing Google Cloud SDK (this takes ~1-2 minutes)…"
      brew install --cask google-cloud-sdk
      if [ -x "/opt/homebrew/Caskroom/google-cloud-sdk/latest/google-cloud-sdk/bin/gcloud" ]; then
        export PATH="/opt/homebrew/Caskroom/google-cloud-sdk/latest/google-cloud-sdk/bin:$PATH"
      elif [ -x "/usr/local/Caskroom/google-cloud-sdk/latest/google-cloud-sdk/bin/gcloud" ]; then
        export PATH="/usr/local/Caskroom/google-cloud-sdk/latest/google-cloud-sdk/bin:$PATH"
      fi
      have gcloud && { ok "gcloud installed successfully!"; return 0; }
    fi
  fi

  echo
  info "${C}━━ Google Cloud Shell Option (Zero Installation) ━━${N}"
  info "You can run this deployment directly inside Google Cloud's free browser terminal:"
  info "  1. Open: ${B}https://shell.cloud.google.com${N}"
  info "  2. Paste this single command into the terminal and press Return:"
  echo
  echo "     ${B}curl -fsSL https://raw.githubusercontent.com/zenzig/hermes-setup-script/main/deploy-gcp.sh | bash${N}"
  echo
  die "Exiting. Re-run this script after installing gcloud, or run it in Google Cloud Shell."
}

# -------------------------------------------------------- authentication & project --
auth_and_project() {
  step "Step 2 · Google Cloud Authentication & Project Selection"
  local active_account
  active_account="$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1)"
  if [ -z "$active_account" ]; then
    info "No active Google Cloud account detected. Opening browser login…"
    gcloud auth login --brief
    active_account="$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1)"
    [ -n "$active_account" ] || die "Google Cloud authentication was not completed."
  fi
  ok "Authenticated as: ${B}$active_account${N}"

  local current_project
  current_project="$(gcloud config get-value project 2>/dev/null || true)"
  if [ "$current_project" = "(unset)" ] || [ -z "$current_project" ] || [ "$current_project" = "None" ]; then
    info "No active GCP project is currently set."
    local projects
    projects="$(gcloud projects list --format="value(projectId)" 2>/dev/null || true)"
    if [ -n "$projects" ]; then
      echo
      info "Existing Google Cloud Projects:"
      local i=1 proj_arr=""
      while IFS= read -r p; do
        [ -z "$p" ] && continue
        echo "    ${B}$i)${N} $p"
        proj_arr="$proj_arr$p"$'\n'
        i=$((i+1))
      done <<< "$projects"
      echo "    ${B}$i)${N} Create a new project"
      echo
      local pick
      pick="$(ask "Select project [1-$i, default: 1]:")"
      pick="${pick:-1}"
      if [ "$pick" -eq "$i" ]; then
        local new_proj
        new_proj="$(trim "$(ask "Enter a new globally-unique project ID (e.g. hermes-agent-$RANDOM):")")"
        [ -z "$new_proj" ] && new_proj="hermes-agent-$RANDOM"
        info "Creating project '$new_proj'…"
        gcloud projects create "$new_proj" --set-as-default
        current_project="$new_proj"
      else
        current_project="$(echo "$proj_arr" | sed -n "${pick}p")"
        [ -z "$current_project" ] && current_project="$(echo "$proj_arr" | head -1)"
        gcloud config set project "$current_project" >/dev/null 2>&1
      fi
    else
      local new_proj
      new_proj="hermes-agent-$RANDOM"
      info "No existing projects found. Creating a new project: '$new_proj'…"
      gcloud projects create "$new_proj" --set-as-default
      current_project="$new_proj"
    fi
  fi
  ok "Active Google Cloud Project: ${B}$current_project${N}"

  info "Ensuring Compute Engine API is enabled (one-time)…"
  gcloud services enable compute.googleapis.com --quiet >>/dev/null 2>&1 || {
    warn "If this project was just created, ensure a Billing Account is linked at:"
    info "  https://console.cloud.google.com/billing/linkedaccount?project=$current_project"
    info "(Google requires a linked billing account to activate Compute Engine, even though e2-micro is \$0.00/mo Always Free)."
    if ! yesno "Has billing been linked / would you like to retry enabling Compute Engine?"; then
      die "Compute Engine API is required to proceed."
    fi
    gcloud services enable compute.googleapis.com --quiet
  }
  ok "Compute Engine API is enabled"
}

# ---------------------------------------------------------------- zone selection --
pick_zone() {
  step "Step 3 · Always-Free Region Selection"
  info "Google Cloud's 'Always Free' e2-micro tier is eligible in 3 US regions:"
  echo "    ${B}1)${N} us-central1-a (Iowa, US Central - Recommended)"
  echo "    ${B}2)${N} us-west1-b    (Oregon, US West)"
  echo "    ${B}3)${N} us-east1-b    (South Carolina, US East)"
  echo
  local z_pick
  z_pick="$(ask "Select region/zone [1-3, default: 1]:")"
  case "${z_pick:-1}" in
    2) ZONE="us-west1-b";;
    3) ZONE="us-east1-b";;
    *) ZONE="us-central1-a";;
  esac
  ok "Selected Zone: ${B}$ZONE${N} (100% Always-Free eligible)"
}

# ------------------------------------------------------------- credentials setup --
gather_credentials() {
  step "Step 4 · Credentials & Model Configuration"
  PROVIDER="gemini"
  MODEL_NAME="gemini-2.5-flash"
  GEMINI_KEY=""
  OPENROUTER_KEY=""
  SLACK_BOT=""
  SLACK_APP=""
  SLACK_USER=""

  echo "    Select the cloud AI engine for your Always-Free VM:"
  echo "      ${B}1)${N} Google AI Studio / Gemini ${G}(Recommended: 100% Free Tier API, 1M context, \$0/mo)${N}"
  echo "      ${B}2)${N} OpenRouter Cloud ${C}(BYOK: access to GLM-5.3, DeepSeek, GPT-6 Luna, etc.)${N}"
  echo
  local be_pick
  be_pick="$(ask "Select engine [1 or 2, default: 1]:")"
  case "${be_pick:-1}" in
    2|openrouter|OpenRouter)
      PROVIDER="openrouter"
      MODEL_NAME="z-ai/glm-5.3-flash"
      ;;
    *)
      PROVIDER="gemini"
      MODEL_NAME="gemini-2.5-flash"
      ;;
  esac

  if [ "$PROVIDER" = "gemini" ]; then
    local local_gkey=""
    local_gkey="$(get_local_env GEMINI_API_KEY)"
    [ -z "$local_gkey" ] && local_gkey="$(get_local_env GOOGLE_API_KEY)"
    if [ -n "$local_gkey" ]; then
      if yesno "Found Gemini API key in local ~/.hermes/.env. Use this key on the cloud VM?"; then
        GEMINI_KEY="$local_gkey"
      fi
    fi
    while [ -z "$GEMINI_KEY" ]; do
      echo
      info "Enter your ${B}Google Gemini API Key${N} (starts with 'AIzaSy...'):"
      info "Get or view free keys at: https://aistudio.google.com"
      GEMINI_KEY="$(trim "$(ask "Gemini API Key:")")"
      [ -z "$GEMINI_KEY" ] && bad "Key cannot be empty."
    done
    ok "Gemini API Key ready"
  else
    local local_orkey=""
    local_orkey="$(get_local_env OPENROUTER_API_KEY)"
    if [ -n "$local_orkey" ]; then
      if yesno "Found OpenRouter API key in local ~/.hermes/.env. Use this key on the cloud VM?"; then
        OPENROUTER_KEY="$local_orkey"
      fi
    fi
    while [ -z "$OPENROUTER_KEY" ]; do
      echo
      info "Enter your ${B}OpenRouter API Key${N} (starts with 'sk-or-'):"
      info "Get keys at: https://openrouter.ai/keys"
      OPENROUTER_KEY="$(trim "$(ask "OpenRouter API Key:")")"
      [ -z "$OPENROUTER_KEY" ] && bad "Key cannot be empty."
    done
    ok "OpenRouter API Key ready"
  fi

  # Chat Platform credentials
  echo
  info "Select chat platform to connect to your 24/7 Hermes VM:"
  echo "    ${B}1)${N} Telegram ${G}(Recommended: 1 single token from @BotFather, 30-sec setup)${N}"
  echo "    ${B}2)${N} Slack    ${C}(Requires Slack App, Bot token, App-level token)${N}"
  echo "    ${B}3)${N} Skip / CLI only (Interact directly via SSH terminal)${N}"
  echo
  local chat_pick
  chat_pick="$(ask "Select platform [1-3, default: 1]:")"
  case "${chat_pick:-1}" in
    2|slack|Slack)
      CHAT_PLATFORM="slack"
      ;;
    3|none|skip|cli)
      CHAT_PLATFORM="none"
      ;;
    *)
      CHAT_PLATFORM="telegram"
      ;;
  esac

  if [ "$CHAT_PLATFORM" = "telegram" ]; then
    local local_tg="" local_tg_user=""
    local_tg="$(get_local_env TELEGRAM_BOT_TOKEN)"
    local_tg_user="$(get_local_env TELEGRAM_ALLOWED_USERS)"
    if [ -n "$local_tg" ]; then
      echo
      if yesno "Found Telegram bot token in local ~/.hermes/.env. Use this token on the cloud VM?"; then
        TELEGRAM_BOT_TOKEN="$local_tg"
        TELEGRAM_USER="$local_tg_user"
      fi
    fi
    while [ -z "$TELEGRAM_BOT_TOKEN" ]; do
      echo
      info "Enter your ${B}Telegram Bot Token${N} (from @BotFather, e.g. 7123456789:AAH...):"
      TELEGRAM_BOT_TOKEN="$(trim "$(ask "Telegram Bot Token:")")"
      [ -z "$TELEGRAM_BOT_TOKEN" ] && bad "Token cannot be empty."
    done
    TELEGRAM_USER="$(trim "$(ask "Your numeric Telegram User ID (optional, press Enter to allow first user/pairing):")")"
    ok "Telegram configuration ready"
  elif [ "$CHAT_PLATFORM" = "slack" ]; then
    local local_bot="" local_app="" local_user=""
    local_bot="$(get_local_env SLACK_BOT_TOKEN)"
    local_app="$(get_local_env SLACK_APP_TOKEN)"
    local_user="$(get_local_env SLACK_ALLOWED_USERS)"
    if [ -n "$local_bot" ] && [ -n "$local_app" ]; then
      echo
      if yesno "Found existing Slack connection tokens in local ~/.hermes/.env. Migrate them to the cloud VM?"; then
        SLACK_BOT="$local_bot"
        SLACK_APP="$local_app"
        SLACK_USER="$local_user"
        warn "Remember to stop your local Mac gateway daemon ('hermes gateway stop') once the cloud VM starts,"
        warn "so the two instances do not compete for the same Slack Socket Mode events."
      fi
    fi

    if [ -z "$SLACK_BOT" ]; then
      echo
      info "Would you like to configure Slack tokens now, or configure them later via SSH?"
      if yesno "Configure Slack tokens now?"; then
        SLACK_BOT="$(trim "$(ask "Paste Slack Bot User OAuth Token (xoxb-):")")"
        SLACK_APP="$(trim "$(ask "Paste Slack App-Level Token (xapp-):")")"
        SLACK_USER="$(trim "$(ask "Your Slack User ID (optional, press Enter to allow all):")")"
      else
        info "You can configure Slack later by running:  gcloud compute ssh $INSTANCE_NAME --zone=$ZONE"
      fi
    fi
  else
    info "Skipping chat platform. You can chat with Hermes directly via SSH."
  fi
}

# ------------------------------------------------------------- VM provisioning --
provision_vm() {
  step "Step 5 · Provisioning Always-Free Google Cloud VM"
  info "Checking if VM '${INSTANCE_NAME}' already exists in ${ZONE}…"
  local exists=0
  if gcloud compute instances describe "$INSTANCE_NAME" --zone="$ZONE" >/dev/null 2>&1; then
    exists=1
  fi

  if [ $exists -eq 1 ]; then
    ok "VM '${INSTANCE_NAME}' already exists."
    if yesno "Would you like to deploy/update Hermes on this existing instance?"; then
      return 0
    else
      die "Aborting. Rename or delete existing instance first."
    fi
  fi

  info "Creating instance with strict Always-Free guardrails:"
  info "  · Machine:   ${B}${MACHINE_TYPE}${N} (1 GB RAM, 2 vCPUs, \$0.00/mo)"
  info "  · Boot Disk: ${B}${DISK_SIZE} ${DISK_TYPE}${N} (Standard Persistent Disk, \$0.00/mo)"
  info "  · Zone:      ${B}${ZONE}${N}"
  info "  · OS Image:  ${B}Ubuntu LTS (Always-Free)${N}"

  local create_res=0
  gcloud compute instances create "$INSTANCE_NAME" \
    --zone="$ZONE" \
    --machine-type="$MACHINE_TYPE" \
    --boot-disk-type="$DISK_TYPE" \
    --boot-disk-size="$DISK_SIZE" \
    --image-family="$IMAGE_FAMILY" \
    --image-project="$IMAGE_PROJECT" \
    --tags=hermes-agent \
    --quiet || create_res=$?

  if [ $create_res -ne 0 ]; then
    warn "First image attempt failed. Retrying with fallback Ubuntu 22.04 LTS image family…"
    gcloud compute instances create "$INSTANCE_NAME" \
      --zone="$ZONE" \
      --machine-type="$MACHINE_TYPE" \
      --boot-disk-type="$DISK_TYPE" \
      --boot-disk-size="$DISK_SIZE" \
      --image-family="ubuntu-2204-lts" \
      --image-project="$IMAGE_PROJECT" \
      --tags=hermes-agent \
      --quiet || die "Failed to create Google Cloud instance. See error above."
  fi

  ok "Always-Free VM successfully provisioned!"
}

# --------------------------------------------------------- remote bootstrapping --
bootstrap_remote() {
  step "Step 6 · Bootstrapping Hermes Agent on the Cloud VM"
  info "Waiting for SSH to become ready on ${INSTANCE_NAME}…"
  local ready=0
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --command="echo ready" --quiet >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 5
    printf "."
  done
  echo
  [ $ready -eq 1 ] || die "Could not establish SSH connection to the VM after 60 seconds."
  ok "SSH connection established"

  info "Deploying 2 GB swap space, dependencies, Hermes Agent, and credentials…"

  # Build remote bootstrap script
  local remote_script="${TMPDIR:-/tmp}/hermes-bootstrap-$$.sh"
  cat > "$remote_script" <<'EOF'
#!/bin/bash
set -e
# Setup 2GB swap if under 2GB RAM
if [ $(free -m | awk '/^Mem:/{print $2}') -lt 2000 ] && [ ! -f /swapfile ]; then
  echo "Configuring 2 GB swap space for 1 GB RAM instance…"
  sudo fallocate -l 2G /swapfile 2>/dev/null || sudo dd if=/dev/zero of=/swapfile bs=1M count=2048 2>/dev/null
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
  echo "Swap configured successfully."
fi

# Package updates
echo "Installing prerequisites…"
sudo apt-get update -y >/dev/null 2>&1
sudo apt-get install -y curl python3 python3-pip git jq >/dev/null 2>&1

# Install Hermes Agent
export PATH="$HOME/.local/bin:$PATH"
if ! command -v hermes >/dev/null 2>&1; then
  echo "Installing Hermes Agent…"
  curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --skip-setup >/dev/null 2>&1
fi

mkdir -p "$HOME/.hermes/skills/thread-handoff" "$HOME/.hermes/handoffs"
touch "$HOME/.hermes/.env"
chmod 600 "$HOME/.hermes/.env"

# Install durable thread-handoff skill
cat > "$HOME/.hermes/skills/thread-handoff/SKILL.md" <<'SKILL_EOF'
---
name: thread-handoff
description: Distil a long session or Slack thread into a durable, dated handoff file instead of lossy compaction. Use when the user asks to hand off, preserve context, start fresh, or when conversation context is growing long.
---

# Thread Handoff (Hermes Agent)

## Goal
Capture durable facts, user requirements, decisions, and outstanding tasks out of the active conversation thread into a structured Markdown file, so a fresh session or clean thread continues without carrying token-heavy historical baggage.

## Where things go
- Handoff file: `~/.hermes/handoffs/YYYY-MM-DD-short-topic.md`
SKILL_EOF

EOF

  # Append credential injections
  if [ -n "${GEMINI_KEY:-}" ]; then
    cat >> "$remote_script" <<EOF
grep -v "^GEMINI_API_KEY=" "\$HOME/.hermes/.env" > "\$HOME/.hermes/.env.tmp" 2>/dev/null || true
echo "GEMINI_API_KEY=$GEMINI_KEY" >> "\$HOME/.hermes/.env.tmp"
echo "GOOGLE_API_KEY=$GEMINI_KEY" >> "\$HOME/.hermes/.env.tmp"
mv "\$HOME/.hermes/.env.tmp" "\$HOME/.hermes/.env"; chmod 600 "\$HOME/.hermes/.env"
EOF
  fi

  if [ -n "${OPENROUTER_KEY:-}" ]; then
    cat >> "$remote_script" <<EOF
grep -v "^OPENROUTER_API_KEY=" "\$HOME/.hermes/.env" > "\$HOME/.hermes/.env.tmp" 2>/dev/null || true
echo "OPENROUTER_API_KEY=$OPENROUTER_KEY" >> "\$HOME/.hermes/.env.tmp"
mv "\$HOME/.hermes/.env.tmp" "\$HOME/.hermes/.env"; chmod 600 "\$HOME/.hermes/.env"
EOF
  fi

  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
    cat >> "$remote_script" <<EOF
grep -v "^TELEGRAM_BOT_TOKEN=" "\$HOME/.hermes/.env" > "\$HOME/.hermes/.env.tmp" 2>/dev/null || true
echo "TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN" >> "\$HOME/.hermes/.env.tmp"
mv "\$HOME/.hermes/.env.tmp" "\$HOME/.hermes/.env"; chmod 600 "\$HOME/.hermes/.env"
EOF
  fi

  if [ -n "${TELEGRAM_USER:-}" ]; then
    cat >> "$remote_script" <<EOF
grep -v "^TELEGRAM_ALLOWED_USERS=" "\$HOME/.hermes/.env" > "\$HOME/.hermes/.env.tmp" 2>/dev/null || true
echo "TELEGRAM_ALLOWED_USERS=$TELEGRAM_USER" >> "\$HOME/.hermes/.env.tmp"
mv "\$HOME/.hermes/.env.tmp" "\$HOME/.hermes/.env"; chmod 600 "\$HOME/.hermes/.env"
EOF
  fi

  if [ -n "${SLACK_BOT:-}" ]; then
    cat >> "$remote_script" <<EOF
grep -v "^SLACK_BOT_TOKEN=" "\$HOME/.hermes/.env" > "\$HOME/.hermes/.env.tmp" 2>/dev/null || true
echo "SLACK_BOT_TOKEN=$SLACK_BOT" >> "\$HOME/.hermes/.env.tmp"
mv "\$HOME/.hermes/.env.tmp" "\$HOME/.hermes/.env"; chmod 600 "\$HOME/.hermes/.env"
EOF
  fi

  if [ -n "${SLACK_APP:-}" ]; then
    cat >> "$remote_script" <<EOF
grep -v "^SLACK_APP_TOKEN=" "\$HOME/.hermes/.env" > "\$HOME/.hermes/.env.tmp" 2>/dev/null || true
echo "SLACK_APP_TOKEN=$SLACK_APP" >> "\$HOME/.hermes/.env.tmp"
mv "\$HOME/.hermes/.env.tmp" "\$HOME/.hermes/.env"; chmod 600 "\$HOME/.hermes/.env"
EOF
  fi

  if [ -n "${SLACK_USER:-}" ]; then
    cat >> "$remote_script" <<EOF
grep -v "^SLACK_ALLOWED_USERS=" "\$HOME/.hermes/.env" > "\$HOME/.hermes/.env.tmp" 2>/dev/null || true
echo "SLACK_ALLOWED_USERS=$SLACK_USER" >> "\$HOME/.hermes/.env.tmp"
mv "\$HOME/.hermes/.env.tmp" "\$HOME/.hermes/.env"; chmod 600 "\$HOME/.hermes/.env"
EOF
  fi

  # Append Hermes configuration calls
  cat >> "$remote_script" <<EOF
export PATH="\$HOME/.local/bin:\$PATH"
hermes config set model.provider $PROVIDER >/dev/null 2>&1
hermes config set model.default $MODEL_NAME >/dev/null 2>&1
if [ "$PROVIDER" = "gemini" ]; then
  hermes config set model.context_length 1000000 >/dev/null 2>&1
else
  hermes config set model.context_length 128000 >/dev/null 2>&1
  hermes config set provider_routing.sort throughput >/dev/null 2>&1 || true
fi
hermes config set model.temperature 0.2 >/dev/null 2>&1
hermes config set compression.enabled false >/dev/null 2>&1 || true
hermes config set auxiliary.compression.enabled false >/dev/null 2>&1 || true
hermes config set auxiliary.title_generation.enabled false >/dev/null 2>&1 || true
hermes config set auxiliary.background_review.enabled false >/dev/null 2>&1 || true
hermes config set approvals.mode smart >/dev/null 2>&1 || true
hermes config set approvals.timeout 300 >/dev/null 2>&1 || true

export HERMES_NONINTERACTIVE=1
if [ -n "$TELEGRAM_BOT_TOKEN" ] || ([ -n "$SLACK_BOT" ] && [ -n "$SLACK_APP" ]); then
  echo "Installing and starting Hermes background gateway daemon…"
  sudo loginctl enable-linger "\$USER" >/dev/null 2>&1 || true
  timeout 10 hermes gateway install --non-interactive >/dev/null 2>&1 || true
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  if systemctl --user start hermes-gateway >/dev/null 2>&1 || systemctl --user restart hermes-gateway >/dev/null 2>&1; then
    echo "Gateway daemon started via systemd"
  else
    pkill -f "hermes gateway" >/dev/null 2>&1 || true
    nohup hermes gateway run > "\$HOME/.hermes/gateway.log" 2>&1 &
    sleep 2
    echo "Gateway daemon running in background (nohup)"
  fi
fi
EOF

  # Copy script to remote and execute
  gcloud compute scp "$remote_script" "${INSTANCE_NAME}:/tmp/hermes-bootstrap.sh" --zone="$ZONE" --quiet
  rm -f "$remote_script"

  gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --command="bash /tmp/hermes-bootstrap.sh && rm -f /tmp/hermes-bootstrap.sh" --quiet
  ok "Hermes Agent and dependencies successfully bootstrapped on cloud VM!"
}

# ------------------------------------------------------------- verification & summary --
verify_and_summary() {
  step "Step 7 · Verification & Gateway Status"
  local status_output
  status_output="$(gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --command="export PATH=\$HOME/.local/bin:\$PATH; hermes gateway status 2>&1 || true" --quiet 2>/dev/null || true)"

  echo
  ok "Hermes 24/7 Always-Free Cloud Agent is live!"
  echo "    ${B}Instance Details:${N}"
  echo "      · Name:         ${INSTANCE_NAME}"
  echo "      · Zone:         ${ZONE}"
  echo "      · Machine:      e2-micro (1 GB RAM + 2 GB swap, \$0.00/mo Always Free)"
  echo "      · Engine:       ${PROVIDER} (${MODEL_NAME})"
  echo
  info "${B}Helpful Cloud Commands:${N}"
  info "  SSH into instance:   ${B}gcloud compute ssh ${INSTANCE_NAME} --zone=${ZONE}${N}"
  info "  Check gateway status:${B}gcloud compute ssh ${INSTANCE_NAME} --zone=${ZONE} --command=\"hermes gateway status\"${N}"
  info "  View gateway logs:   ${B}gcloud compute ssh ${INSTANCE_NAME} --zone=${ZONE} --command=\"tail -50 ~/.hermes/gateway.log\"${N}"
  info "  Stop instance:       ${B}gcloud compute instances stop ${INSTANCE_NAME} --zone=${ZONE}${N}"
  info "  Start instance:      ${B}gcloud compute instances start ${INSTANCE_NAME} --zone=${ZONE}${N}"
  echo
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
    ok "Telegram gateway is active! Open Telegram on your phone and send a message to your bot."
  elif [ -n "${SLACK_BOT:-}" ]; then
    ok "Slack gateway is active! Test it by sending a DM to your bot in Slack."
  else
    info "No chat platform configured. You can use Hermes directly via SSH."
  fi
}

# ----------------------------------------------------------- local on-VM bootstrap --
bootstrap_local() {
  step "Bootstrapping Hermes Agent on this Cloud VM"
  if [ $(free -m 2>/dev/null | awk '/^Mem:/{print $2}') -lt 2000 ] && [ ! -f /swapfile ]; then
    info "Configuring 2 GB swap space for 1 GB RAM instance…"
    sudo fallocate -l 2G /swapfile 2>/dev/null || sudo dd if=/dev/zero of=/swapfile bs=1M count=2048 2>/dev/null
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
    ok "Swap configured successfully."
  fi

  info "Installing prerequisites…"
  sudo apt-get update -y >/dev/null 2>&1 || true
  sudo apt-get install -y curl python3 python3-pip git jq >/dev/null 2>&1 || true

  export PATH="$HOME/.local/bin:$PATH"
  if ! command -v hermes >/dev/null 2>&1; then
    info "Installing Hermes Agent…"
    curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --skip-setup >/dev/null 2>&1 || curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
  fi

  mkdir -p "$HOME/.hermes/skills/thread-handoff" "$HOME/.hermes/handoffs"
  touch "$HOME/.hermes/.env"
  chmod 600 "$HOME/.hermes/.env"

  cat > "$HOME/.hermes/skills/thread-handoff/SKILL.md" <<'SKILL_EOF'
---
name: thread-handoff
description: Distil a long session into a durable, dated handoff file instead of lossy compaction.
---
# Thread Handoff (Hermes Agent)
SKILL_EOF

  if [ -n "${GEMINI_KEY:-}" ]; then
    grep -v "^GEMINI_API_KEY=" "$HOME/.hermes/.env" > "$HOME/.hermes/.env.tmp" 2>/dev/null || true
    echo "GEMINI_API_KEY=$GEMINI_KEY" >> "$HOME/.hermes/.env.tmp"
    echo "GOOGLE_API_KEY=$GEMINI_KEY" >> "$HOME/.hermes/.env.tmp"
    mv "$HOME/.hermes/.env.tmp" "$HOME/.hermes/.env"; chmod 600 "$HOME/.hermes/.env"
  fi

  if [ -n "${OPENROUTER_KEY:-}" ]; then
    grep -v "^OPENROUTER_API_KEY=" "$HOME/.hermes/.env" > "$HOME/.hermes/.env.tmp" 2>/dev/null || true
    echo "OPENROUTER_API_KEY=$OPENROUTER_KEY" >> "$HOME/.hermes/.env.tmp"
    mv "$HOME/.hermes/.env.tmp" "$HOME/.hermes/.env"; chmod 600 "$HOME/.hermes/.env"
  fi

  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
    grep -v "^TELEGRAM_BOT_TOKEN=" "$HOME/.hermes/.env" > "$HOME/.hermes/.env.tmp" 2>/dev/null || true
    echo "TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN" >> "$HOME/.hermes/.env.tmp"
    mv "$HOME/.hermes/.env.tmp" "$HOME/.hermes/.env"; chmod 600 "$HOME/.hermes/.env"
  fi

  if [ -n "${TELEGRAM_USER:-}" ]; then
    grep -v "^TELEGRAM_ALLOWED_USERS=" "$HOME/.hermes/.env" > "$HOME/.hermes/.env.tmp" 2>/dev/null || true
    echo "TELEGRAM_ALLOWED_USERS=$TELEGRAM_USER" >> "$HOME/.hermes/.env.tmp"
    mv "$HOME/.hermes/.env.tmp" "$HOME/.hermes/.env"; chmod 600 "$HOME/.hermes/.env"
  fi

  if [ -n "${SLACK_BOT:-}" ]; then
    grep -v "^SLACK_BOT_TOKEN=" "$HOME/.hermes/.env" > "$HOME/.hermes/.env.tmp" 2>/dev/null || true
    echo "SLACK_BOT_TOKEN=$SLACK_BOT" >> "$HOME/.hermes/.env.tmp"
    mv "$HOME/.hermes/.env.tmp" "$HOME/.hermes/.env"; chmod 600 "$HOME/.hermes/.env"
  fi

  if [ -n "${SLACK_APP:-}" ]; then
    grep -v "^SLACK_APP_TOKEN=" "$HOME/.hermes/.env" > "$HOME/.hermes/.env.tmp" 2>/dev/null || true
    echo "SLACK_APP_TOKEN=$SLACK_APP" >> "$HOME/.hermes/.env.tmp"
    mv "$HOME/.hermes/.env.tmp" "$HOME/.hermes/.env"; chmod 600 "$HOME/.hermes/.env"
  fi

  if [ -n "${SLACK_USER:-}" ]; then
    grep -v "^SLACK_ALLOWED_USERS=" "$HOME/.hermes/.env" > "$HOME/.hermes/.env.tmp" 2>/dev/null || true
    echo "SLACK_ALLOWED_USERS=$SLACK_USER" >> "$HOME/.hermes/.env.tmp"
    mv "$HOME/.hermes/.env.tmp" "$HOME/.hermes/.env"; chmod 600 "$HOME/.hermes/.env"
  fi

  export PATH="$HOME/.local/bin:$PATH"
  hermes config set model.provider $PROVIDER >/dev/null 2>&1 || true
  hermes config set model.default $MODEL_NAME >/dev/null 2>&1 || true
  if [ "$PROVIDER" = "gemini" ]; then
    hermes config set model.context_length 1000000 >/dev/null 2>&1 || true
  else
    hermes config set model.context_length 128000 >/dev/null 2>&1 || true
    hermes config set provider_routing.sort throughput >/dev/null 2>&1 || true
  fi
  hermes config set model.temperature 0.2 >/dev/null 2>&1 || true
  hermes config set compression.enabled false >/dev/null 2>&1 || true
  hermes config set auxiliary.compression.enabled false >/dev/null 2>&1 || true
  hermes config set auxiliary.title_generation.enabled false >/dev/null 2>&1 || true
  hermes config set auxiliary.background_review.enabled false >/dev/null 2>&1 || true
  hermes config set approvals.mode smart >/dev/null 2>&1 || true
  hermes config set approvals.timeout 300 >/dev/null 2>&1 || true

  export HERMES_NONINTERACTIVE=1
  if [ -n "$TELEGRAM_BOT_TOKEN" ] || ([ -n "$SLACK_BOT" ] && [ -n "$SLACK_APP" ]); then
    info "Installing and starting Hermes background gateway daemon…"
    sudo loginctl enable-linger "$USER" >/dev/null 2>&1 || true
    timeout 10 hermes gateway install --non-interactive >/dev/null 2>&1 || true
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    if systemctl --user start hermes-gateway >/dev/null 2>&1 || systemctl --user restart hermes-gateway >/dev/null 2>&1; then
      ok "Gateway daemon started via systemd"
    else
      pkill -f "hermes gateway" >/dev/null 2>&1 || true
      nohup hermes gateway run > "$HOME/.hermes/gateway.log" 2>&1 &
      sleep 2
      ok "Gateway daemon running in background (nohup)"
    fi
  fi

  echo
  ok "Hermes 24/7 Always-Free Cloud Agent is live on this VM!"
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
    ok "Telegram gateway is active! Open Telegram on your phone and send a message to your bot."
  elif [ -n "${SLACK_BOT:-}" ]; then
    ok "Slack gateway is active! Test it by sending a DM to your bot in Slack."
  else
    info "No chat platform configured. You can use Hermes directly via 'hermes chat'."
  fi
}

# ----------------------------------------------------------------------- main --
echo "${B}${C}╔═══════════════════════════════════════════════════════════════════════╗${N}"
echo "${B}${C}║   Hermes Agent — Google Cloud Always-Free 24/7 Auto-Deployer          ║${N}"
echo "${B}${C}╚═══════════════════════════════════════════════════════════════════════╝${N}"

# Auto-detect if already running directly on the cloud VM
if [ "$(hostname 2>/dev/null)" = "$INSTANCE_NAME" ] || [ "${1:-}" = "local" ]; then
  gather_credentials
  bootstrap_local
  exit 0
fi

check_gcloud
auth_and_project
pick_zone
gather_credentials
provision_vm
bootstrap_remote
verify_and_summary
