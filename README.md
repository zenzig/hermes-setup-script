# Hermes Easy Setup

A guided macOS setup script for Hermes Agent, a local AI model, and Slack.

Designed for Apple Silicon Mac users, including people who are new to Terminal. The script walks you through choosing a model, configuring Ollama or LM Studio, installing Hermes, and connecting a Slack bot.

## Requirements

- macOS, with Apple Silicon as the primary target (M1 through M4, 16 GB to 48 GB+).
- An internet connection for installers, model downloads, and Slack.
- Memory and storage:
  - **Dynamic Unified Memory Analysis:** Setup dynamically calculates physical RAM, reserves dedicated headroom for macOS (kernel, WindowServer, Slack, IDE), and establishes a safe model memory ceiling.
  - **16 GB Macs (e.g. M1 16 GB):** Hermes requires a 64K (65,536 token) context window for agent tool calling. Ollama is recommended on 16 GB because its 8-bit quantized KV cache (`OLLAMA_KV_CACHE_TYPE q8_0`) and Flash Attention cut long-context memory by 50% on the Metal GPU, preventing unified memory exhaustion. LM Studio is supported with auto-balanced offload and active canary surveillance.
  - **36 GB / 48 GB+ Macs (e.g. M4 48 GB):** Substantial memory allows running high-capacity Mixture-of-Experts (MoE) models (e.g. Qwen3.6 35B-A3B or Qwen3-Coder 30B-A3B) with full 64K context and dedicated GPU acceleration under LM Studio (MLX) or Ollama.
  - Disk space: At least 15–30 GB free recommended depending on model choice.
- Ollama or LM Studio. Both run directly on Apple Silicon's Metal GPU.
- Apple's Command Line Tools and `python3`. The script prompts to install developer tools if missing; Python is used for JSON processing and benchmarking.
- A Slack workspace where you can create and install an app. The guided flow can help you create a workspace and sign in through your browser.

The script is written for the stock macOS Bash 3.2. Run it as your normal macOS user.

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

Follow the Terminal prompts and return to Terminal whenever a browser or app step finishes. Model downloads can take substantial time and disk space.

## Commands

| Command | What it does |
| --- | --- |
| `bash hermes-easy-setup.sh` | Runs the full setup, including Slack. |
| `bash hermes-easy-setup.sh all` | Explicitly runs the full setup. |
| `bash hermes-easy-setup.sh model` | Selects, downloads, tunes, and canary-benchmarks a model; also installs or updates Hermes configuration. |
| `bash hermes-easy-setup.sh slack` | Sets up or validates Slack and installs the Hermes gateway service. Requires Hermes to be installed already. |
| `bash hermes-easy-setup.sh doctor` | Checks memory health, validates model server under canary watchdog, checks Slack tokens, and runs diagnostics. |

Every mode runs the macOS preflight first. Although the diagnostic output says nothing will change, `doctor` can create the Hermes directory/log, trigger the Command Line Tools installation prompt, run inference under the canary watchdog, and contact Slack.

## What setup does

1. **Hardware profiling & Dynamic Memory Bounds:** Evaluates CPU architecture, Apple Silicon chip tier, unified RAM capacity, and free disk space. Calculates a dynamic safe model budget (reserving 4.5–10 GB for macOS and applications) to prevent driver-level memory exhaustion.
2. **Backend detection & Guidance:** Detects LM Studio and Ollama. On < 24 GB systems, recommends Ollama for its quantized KV cache safety on Metal; on >= 24 GB systems, recommends LM Studio's MLX engine.
3. **Model recommendations:** Presents curated, downloadable models tailored for Hermes agent workflows and tool-calling fidelity. For 16 GB machines, prioritizes compact, stable models (Hermes 3 3B, Qwen3 4B).
4. **Tuning & Context sizing:**
   - **LM Studio (MLX):** Checks and installs the Apple Silicon `mlx-llm` extension, verifies resource guardrails with `--estimate-only`, applies dynamic offload (auto-balanced on < 32 GB), loads with 64K context and single-slot concurrency (`--parallel 1`), and configures automatic reload on reboot.
   - **Ollama:** Enables Flash Attention (`OLLAMA_FLASH_ATTENTION 1`), 8-bit KV caching (`OLLAMA_KV_CACHE_TYPE q8_0`), 64K context limit, and single concurrency.
5. **Canary Verification & Memory Watchdog:** Runs a real-time background watchdog during warmup and speed testing that samples resident memory (RSS). If memory starts runaway expansion toward the hardware ceiling, the watchdog immediately unloads the model before macOS can trigger an `IOGPUFamily` kernel panic, and safely transitions to a lighter configuration.
6. **Hermes Agent configuration:** Sets up Hermes with the chosen provider, points it to the local endpoint with a 65,536 context length, and configures timeouts and local optimizations.
7. **Slack connection:** Generates the app manifest, guides token setup, configures security/allowed users, and installs the background gateway daemon.

### Ollama (Recommended for 16 GB Macs)

Uses `http://localhost:11434/v1`. Runs 100% on Apple Silicon Metal GPU. Setup enables flash attention and an 8-bit KV cache, sets a 24-hour keep-alive, limits parallelism to 1, and restarts Ollama. It creates a tuned `hermes-local` model with 64K context and a login LaunchAgent that persists the environment settings.

### LM Studio (Recommended for 24 GB+ Macs)

Uses `http://localhost:1234/v1`. Setup verifies the native Apple Silicon MLX runtime, downloads the selected model, tests guardrails, applies dynamic GPU offload, and loads with 64K context and `--parallel 1` concurrency. It configures a LaunchAgent to maintain the service across restarts.

### Slack

The guided route copies the generated JSON manifest to your clipboard and opens the Slack app setup pages. It asks for:

- A bot token beginning with `xoxb-`.
- An app-level token beginning with `xapp-`, with `connections:write` for Socket Mode.
- Your Slack member identity, unless `SLACK_ALLOWED_USERS` is already configured.

Existing working tokens and an existing allowed-user list are retained. The script checks the bot token against its required scopes when Slack returns that information.

## Advanced options

Set these environment variables for a single invocation:

| Variable | Values / purpose |
| --- | --- |
| `HERMES_BACKEND` | `ollama` or `lmstudio`; overrides automatic backend selection. The chosen engine must be available. |
| `HERMES_MODEL_OVERRIDE` | An Ollama model tag or LM Studio model repository, according to the selected backend. |
| `HERMES_SLACK_AUTO` | Set to `1` to try the experimental Slack CLI setup path, with guided setup as a fallback. This path may install the Slack CLI. |

For example:

```bash
HERMES_BACKEND=ollama bash hermes-easy-setup.sh model
```

The model override still runs after the catalog availability checks; it does not bypass a failure to find an available model in your memory tier.

## Files and settings

| Path | Purpose |
| --- | --- |
| `~/.hermes/config.yaml` | Hermes model configuration. |
| `~/.hermes/config.yaml.before-easy-setup` | One-time backup of an existing configuration, created if no backup exists yet. |
| `~/.hermes/.env` | Slack tokens, allowed users, and `HERMES_API_TIMEOUT=1800`; saved with owner-only permissions. |
| `~/.hermes/slack-manifest.json` | Generated Slack app manifest. |
| `~/.hermes/easy-setup.log` | Selected installer, configuration, and service output. |
| `~/.hermes/start-local-model.sh` | LM Studio startup helper, when that backend is selected. |
| `~/Library/LaunchAgents/com.hermes-easy.ollama-env.plist` | Ollama login environment settings. |
| `~/Library/LaunchAgents/com.hermes-easy.lmstudio.plist` | LM Studio login startup configuration. |

Setup downloads and runs external installers when needed, changes local model settings, and installs background services. Re-running it reuses some existing installation and Slack state, but model setup still reloads or restarts the engine and rewrites settings. Back up any configuration you want to preserve before running it.

Keep Slack tokens and `~/.hermes/.env` private. Token prompts are visible in Terminal; avoid screen sharing while entering them. Review logs before sharing them for troubleshooting. Model inference uses your local server, while Slack messages and setup requests still use external services.

## Troubleshooting

Start with:

```bash
bash hermes-easy-setup.sh doctor
```

- **Model download or availability failure:** Check your internet connection and the selected model's availability. The catalog checks only the current memory tier.
- **Model will not load or runs slowly:** Close memory-heavy apps, check free memory/storage, and run `model` again to choose another available model.
- **Missing `lms`:** Open LM Studio and make sure its command-line helper is available before retrying.
- **Slack rejects a token or reports missing scopes:** Check that you used the correct token type, created the app from the generated manifest, and reinstalled it after permission changes. Run `slack` again.
- **Bot does not reply:** Check `SLACK_ALLOWED_USERS`, the gateway status, and the diagnostics output. A successful setup DM alone does not verify a complete model-backed conversation.
- **Further details:** Inspect `~/.hermes/easy-setup.log`; it contains selected command output, not a complete transcript.

## License

Licensed under the [MIT License](LICENSE).
