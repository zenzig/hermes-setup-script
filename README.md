# Hermes Easy Setup

A guided setup script for Hermes Agent, local/cloud AI models, Slack, and Google Cloud 24/7 deployments.

Designed for all Mac and Linux users, including people who are new to Terminal. The script walks you through choosing an AI engine—**Google AI Studio (Gemini Free Tier)**, **OpenRouter Cloud (BYOK)**, or **Local Models (Ollama / LM Studio)**—configuring model parameters, installing Hermes, connecting a Slack bot, and optionally deploying Hermes 24/7 to Google Cloud's **Always Free** tier.

## Requirements

- **Operating System:** macOS (Apple Silicon M1–M4 or Intel x86_64) or Linux (Ubuntu / Debian / GCP).
- **An internet connection** for installers, model downloads, and Slack.
- **Engine choice**:
  - **Google AI Studio / Gemini (Recommended - 100% Free):** Free tier API access with massive **1,000,000 token context window**, zero Mac memory load, and fast agent tool calling.
  - **OpenRouter Cloud (BYOK):** Instant setup with zero local RAM requirements. Validates your API key and live credit balance upfront.
  - **Local Apple Silicon (16 GB to 48 GB+ Unified RAM):** Runs 100% on Apple Silicon Metal GPU. Dynamic memory bounds calculate safe RAM ceilings (reserving 4.5–10 GB for macOS) and run a real-time Canary Memory Watchdog to prevent driver-level memory exhaustion.
  - **Local Intel Macs:** Detects Intel architecture and runs verified GGUF model repositories on Metal/CPU (avoiding non-functional MLX builds).
- **Apple Command Line Tools and `python3` (Mac):** The script prompts to install developer tools if missing; Python is used for JSON processing and benchmarking.
- **Slack Workspace:** Where you can create and install an app. The guided flow helps you create a workspace and sign in through your browser.

The script is written for stock macOS / Linux Bash. Run it as your normal user.

## Quick start

Download this repository using GitHub's **Code → Download ZIP**, unzip it, and open Terminal in the extracted folder. Alternatively, clone it:

```bash
git clone https://github.com/zenzig/hermes-setup-script.git
cd hermes-setup-script
```

Start the guided setup:

```bash
bash hermes-easy-setup.sh
```

Follow the Terminal prompts and return to Terminal whenever a browser or app step finishes.

## Commands

| Command | What it does |
| --- | --- |
| `bash hermes-easy-setup.sh` | Runs the full guided setup, including Slack. |
| `bash hermes-easy-setup.sh all` | Explicitly runs the full setup. |
| `bash hermes-easy-setup.sh model` | Selects, configures, and benchmarks a cloud or local model; also installs/updates Hermes configuration. |
| `bash hermes-easy-setup.sh slack` | Sets up or validates Slack and installs the Hermes gateway daemon. Requires Hermes to be installed already. |
| `bash hermes-easy-setup.sh doctor` | Validates API keys, balances, local servers under watchdog, Slack tokens, and gateway diagnostics. |
| `bash hermes-easy-setup.sh reset` | Clean wipe: stops daemons, cleans LaunchAgents, removes `~/.hermes`, and resets to a blank slate. |
| `bash hermes-easy-setup.sh gcp` | **Automated 24/7 Google Cloud Deployer:** Provisions an Always-Free `e2-micro` VM on GCP with Hermes pre-configured. |

---

## What setup does

### 1. Engine Selection & Preflight
Choose between **Google AI Studio (Gemini)**, **OpenRouter Cloud (BYOK)**, or **Local Engine (Ollama / LM Studio)**:
* **Google AI Studio / Gemini (100% Free):**
  * Prompts for your Gemini API key (starts with `AIzaSy...`).
  * Validates key against Google AI Studio API.
  * Presets: **Gemini 2.5 Flash** (high speed, 1M context), **Gemini 2.5 Pro** (deep reasoning), and **Gemini 1.5 Flash**.
  * Saves `GEMINI_API_KEY` and `GOOGLE_API_KEY` to `~/.hermes/.env` (`chmod 600`).
* **OpenRouter Cloud (BYOK):**
  * Prompts for your `OPENROUTER_API_KEY`.
  * Instantly validates key format and queries your live credit balance via OpenRouter API.
  * Curates 4 high-efficiency agent presets:
    1. **GLM-5.3 Flash** (`z-ai/glm-5.3-flash`): High-speed, elite reasoning & tool execution.
    2. **DeepSeek V4 Flash** (`deepseek/deepseek-v4-flash-0731`): Next-gen coding & fast agent problem solving.
    3. **GPT-6 Luna Pro** (`openai/gpt-6-luna-pro`): Flagship enterprise intelligence & precision.
    4. **Qwen 3.7 Flash** (`qwen/qwen3.7-flash`): Ultra-snappy, cost-effective agent workhorse.
    5. **Custom Slug**: Manual entry for specific models or private endpoints.
* **Local Engine:**
  * Detects installed engines and CPU architecture (`arm64` vs Intel `x86_64`).
  * On < 24 GB Apple Silicon: Recommends Ollama for 8-bit quantized KV caching on Metal.
  * On >= 24 GB Apple Silicon: Recommends LM Studio's MLX engine.
  * On Intel Macs: Restricts models to verified GGUF weights on Metal/CPU.

### 2. Durable Thread Handoffs (replacing lossy compaction)
Hermes' native in-flight LLM compaction produces "summaries of summaries" where early decisions blur and resends thousands of accumulated tokens on every Slack turn.

Setup replaces native lossy compaction with an **`agent-thread-tools` Durable Handoff Skill** (`~/.hermes/skills/thread-handoff/SKILL.md`):
* In Slack or Terminal, triggering `/handoff` extracts durable project facts, decisions, and action items into a clean Markdown brief (`~/.hermes/handoffs/YYYY-MM-DD-topic.md`).
* Future sessions or new Slack threads start fresh with 0 accumulated token bloat while retaining durable project state.

### 3. Harness & Parameter Optimizations
* **Provider Routing:** Configures OpenRouter `sort: throughput` for snappy streaming, `require_parameters: true` to skip broken third-party hosts, and `data_collection: deny` for prompt privacy.
* **Tool Calling Temperature:** Sets `model.temperature: 0.2` to eliminate JSON syntax hallucinations during tool execution.
* **Approvals & Daemon Safety:** Configures `approvals.mode smart` (timeout: 300s) so headless Slack daemons do not deadlock waiting for terminal confirmation.

### 4. Canary Verification & Latency Test
* **Google Gemini & OpenRouter:** Runs a warmup completion, measures round-trip network latency, and displays tokens per second.
* **Local Models:** Starts a real-time background watchdog that samples resident memory (RSS) every 250ms. If memory surges toward the hardware ceiling, the watchdog instantly unloads the model before macOS can trigger a driver kernel panic.

### 5. Slack Connection
* Generates `slack-manifest.json` and copies it to your clipboard.
* Opens the Slack app creation page.
* Guides pasting the manifest and extracting Bot Token (`xoxb-`) and App-Level Socket Mode Token (`xapp-`).
* Validates all 14 required OAuth scopes.
* Automatically installs and starts `hermes gateway` as a background daemon and sends a live test DM in Slack.

---

## 24/7 Always-Free Google Cloud Deployment

If you want Hermes running 24/7 without needing your Mac turned on, Google Cloud offers an **"Always Free"** tier for Compute Engine that costs **\$0.00/month forever**.

You can automate this entire cloud setup in two ways:

### Option A: From your Mac via `gcloud`
Run:
```bash
bash hermes-easy-setup.sh gcp
# or:
./deploy-gcp.sh
```
The script will:
1. Verify or help install the `gcloud` SDK.
2. Ensure strict **Always-Free guardrails** to guarantee zero charges:
   - Machine type: `e2-micro` (2 vCPU, 1 GB RAM — \$0.00)
   - Boot disk: `pd-standard` 30 GB (Standard Persistent Disk — \$0.00)
   - Region: `us-central1` (Iowa), `us-west1` (Oregon), or `us-east1` (SC)
3. Migrate your local API keys and Slack tokens to the VM.
4. Provision 2 GB swap space on the VM (to comfortably host Hermes in 1 GB RAM).
5. Install Hermes Agent, configure Gemini (or OpenRouter), and start the 24/7 background gateway daemon.

### Option B: Zero-Install via Google Cloud Shell (Web Browser)
If you do not want to install anything on your Mac, use Google's free in-browser terminal:
1. Open **[Google Cloud Shell](https://shell.cloud.google.com)**.
2. Paste and run this one-liner:
```bash
curl -fsSL https://raw.githubusercontent.com/zenzig/hermes-setup-script/main/deploy-gcp.sh -o deploy.sh && bash deploy.sh
```

---

## API Quotas & Cost Breakdown (Free vs. Pay-As-You-Go)

### 1. Google Cloud VM Infrastructure: $0.00 / month (Always Free)
* **Compute Engine**: `e2-micro` (2 vCPUs, 1 GB RAM) is covered 100% under Google Cloud's "Always Free" tier (744 pooled hours/month in `us-central1`, `us-west1`, or `us-east1`).
* **Disk**: 30 GB standard persistent disk (`pd-standard`) is also 100% $0.00/month.
* **Swap Space**: The script automatically provisions 2 GB of swap space so Hermes runs smoothly in 1 GB RAM without out-of-memory errors.

### 2. AI Model API: Free Tier Quotas vs. Paid Plan (~$0.25 – $1.50 / month)

#### The Free Tier Caveat (15 Requests/Minute)
Google AI Studio offers a free tier for Gemini API keys. However:
* It has a strict quota of **15 Requests Per Minute (RPM)**.
* Because Hermes is an **autonomous agent** that runs multi-step tool loops (analyzing → running bash commands → checking files → evaluating results), a single complex user task can trigger 3–10 internal LLM calls in rapid succession.
* On pure free accounts, this can trigger `HTTP 429 RESOURCE_EXHAUSTED` rate-limit errors during active agent sessions.

#### Upgrading to Pay-As-You-Go (Recommended)
Upgrading your Google Cloud project to Pay-As-You-Go immediately unlocks **1,000+ RPM** with zero throttling:

| Resource | Free Tier | Pay-As-You-Go Plan | Approximate Monthly Cost |
| :--- | :--- | :--- | :--- |
| **VM Infrastructure** | `e2-micro` (30GB disk) | `e2-micro` (30GB disk) | **$0.00** (Always Free) |
| **API Rate Limit** | 15 RPM (throttled) | 1,000+ RPM (unthrottled) | — |
| **Gemini Flash API** | 15 RPM / 1,500 RPD | $0.075 / 1,000,000 input tokens | **~$0.25 – $1.50 / month** |

* A typical active user (~15–30 tasks/day) uses roughly 50,000–200,000 tokens/day.
* At $0.075 per 1M tokens, adding a **$10 or $20 credit balance** to your Google account powers Hermes for **6 to 12+ months**!

#### How to Add Payment to your Account
1. Open **[Google AI Studio Plan Settings](https://aistudio.google.com/app/plan_information)** (or [Google Cloud Billing](https://console.cloud.google.com/billing)).
2. Click **"Set up billing"** or **"Upgrade to Pay-as-you-go"** on your project and link a payment method.
3. Your existing API keys automatically inherit the upgraded 1,000+ RPM limits within minutes—no key regeneration or server restarts needed.

---

## Advanced options

Set environment variables for automated or custom invocations:

| Variable | Values / purpose |
| --- | --- |
| `HERMES_BACKEND` | `gemini`, `openrouter`, `ollama`, or `lmstudio`; overrides interactive engine selection. |
| `HERMES_GEMINI_KEY` | Pre-sets the Google Gemini API key (`AIzaSy...`), bypassing interactive input. |
| `HERMES_OPENROUTER_KEY` | Pre-sets the OpenRouter API key, bypassing interactive input. |
| `HERMES_MODEL_OVERRIDE` | A model slug (e.g. `gemini-2.5-flash`, `z-ai/glm-5.3-flash`, `qwen2.5-coder:7b`). |
| `HERMES_SLACK_AUTO` | Set to `1` to try the experimental Slack CLI setup path. |

For example:

```bash
HERMES_BACKEND=gemini HERMES_GEMINI_KEY=AIzaSy... bash hermes-easy-setup.sh model
```

---

## Files and settings

| Path | Purpose |
| --- | --- |
| `deploy-gcp.sh` | Google Cloud Always-Free automated deployer script. |
| `~/.hermes/config.yaml` | Hermes model, provider routing, and approval settings. |
| `~/.hermes/config.yaml.before-easy-setup` | Backup of existing configuration prior to setup. |
| `~/.hermes/.env` | Gemini API key, OpenRouter key, Slack tokens, allowed users, and timeouts (`chmod 600`). |
| `~/.hermes/skills/thread-handoff/SKILL.md` | Durable thread handoff skill (replaces lossy LLM compaction). |
| `~/.hermes/handoffs/` | Directory where thread handoff briefs are archived. |
| `~/.hermes/slack-manifest.json` | Generated Slack app manifest. |
| `~/.hermes/easy-setup.log` | Selected installer, configuration, and service output. |
| `~/.hermes/start-local-model.sh` | LM Studio startup helper, when local LM Studio is selected. |
| `~/Library/LaunchAgents/com.hermes-easy.ollama-env.plist` | Ollama login environment settings. |
| `~/Library/LaunchAgents/com.hermes-easy.lmstudio.plist` | LM Studio login startup configuration. |

---

## Troubleshooting

Start with:

```bash
bash hermes-easy-setup.sh doctor
```

- **Google Gemini Key Rejected:** Ensure your key starts with `AIzaSy` and test it at [aistudio.google.com](https://aistudio.google.com).
- **OpenRouter Key Rejected or $0 Balance:** Verify your key at [openrouter.ai/keys](https://openrouter.ai/keys) and ensure your account has active credits at [openrouter.ai/credits](https://openrouter.ai/credits).
- **Intel Mac LM Studio Download Error:** Intel Macs require GGUF models. Setup automatically targets GGUF fallbacks. Ensure LM Studio is updated.
- **Local Model Exceeds Memory:** Close background apps and re-run `bash hermes-easy-setup.sh model` to pick a more compact model, or switch to Google Gemini / OpenRouter Cloud.
- **Slack Token or Scopes Mismatch:** Re-run `bash hermes-easy-setup.sh slack` to regenerate the manifest and reinstall the app.
- **Bot Does Not Reply in Slack:** Run `bash hermes-easy-setup.sh doctor` to inspect gateway daemon status and verify that `SLACK_ALLOWED_USERS` contains your Slack member ID.

## License

Licensed under the [MIT License](LICENSE).
