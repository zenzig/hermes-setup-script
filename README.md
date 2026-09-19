# Hermes Easy Setup

A guided macOS setup script for Hermes Agent, a local AI model, and Slack.

Designed for Apple Silicon Mac users, including people who are new to Terminal. The script walks you through choosing a model, configuring Ollama or LM Studio, installing Hermes, and connecting a Slack bot.

## Requirements

- macOS, with Apple Silicon as the intended target.
- An internet connection for installers, model downloads, and Slack.
- Enough memory and storage for your model. The script offers memory tiers starting at 8 GB and warns when less than 30 GB of disk space is available. These checks do not guarantee that a model will fit, especially with the configured 65,536-token context.
- Ollama or LM Studio. If neither is detected, the script opens the Ollama download page and waits for you to install it.
- Apple's Command Line Tools and `python3`. The script prompts to install the developer tools if missing; Python is used for JSON processing and benchmarking.
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
| `bash hermes-easy-setup.sh model` | Selects, downloads, tunes, and benchmarks a model; also installs or updates Hermes configuration. |
| `bash hermes-easy-setup.sh slack` | Sets up or validates Slack and installs the Hermes gateway service. Requires Hermes to be installed already. |
| `bash hermes-easy-setup.sh doctor` | Checks the model server, benchmarks it when available, validates Slack tokens, and runs Hermes diagnostics. |

Every mode runs the macOS preflight first. Although the diagnostic output says nothing will change, `doctor` can create the Hermes directory/log, trigger the Command Line Tools installation prompt, run inference, and contact Slack. It is not a strictly read-only or offline check.

## What setup does

1. Detects the Mac's memory, disk space, and available model engines.
2. Offers models from the script's built-in catalog for the detected memory tier, checking download availability before presenting them.
3. Configures the selected model under the stable name `hermes-local` with a 65,536-token context and runs a speed test.
4. Runs the Hermes installer if needed and points Hermes at the local model server.
5. Generates a Slack app manifest, guides you through creating and installing the app, validates its tokens, and configures allowed Slack users.
6. Installs the Hermes gateway background service and attempts to send a setup DM to the first allowed Slack user.

Backend selection prefers an existing Ollama installation on Macs with less than 24 GB of memory, then LM Studio on Apple Silicon, then whichever supported engine is available. Model catalog entries and compatibility depend on the external services and software versions available when you run the script.

### Ollama

Uses `http://localhost:11434/v1`. Setup enables flash attention and an 8-bit KV cache, sets a 24-hour keep-alive, limits parallelism and loaded models to one, and restarts Ollama. It creates a tuned `hermes-local` model and a login LaunchAgent that reapplies the environment settings.

### LM Studio

Uses `http://localhost:1234/v1`. Setup downloads the selected model, unloads currently loaded models, and loads `hermes-local` with the configured context and GPU settings. It also creates a helper script and login LaunchAgent to start the server and reload the model.

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
