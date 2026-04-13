# dothething

Dothething (DTT) is a local AI agent. You give it a task, walk away, and come back to results.

It handles research, data extraction, browser automation, file editing, and code execution. It works until the job is done, or tells you exactly why it couldn't.

**Website:** [dotheth.ing](https://dotheth.ing)

## What it does

You describe a task in plain English. The agent breaks it down, picks the right tools, and delivers the output.

- Plans its work and tracks progress
- Searches the web using a local SearXNG instance (supports Google, Bing, DuckDuckGo, and more -- you can target specific engines or search images directly)
- Browses pages with Notte and Camoufox (a Firefox fork built to avoid fingerprinting). Extracts page content, solves captchas, and handles multi-step web interactions
- Reads and edits files, runs shell commands, makes HTTP requests
- Connects to your existing MCP servers via `~/.dtt/mcp.json`
- Loads custom skills from `~/.dtt/skills/<skill-name>/SKILL.md` (Claude Code convention) -- behavioral skills inject directly into the agent's context, while text-processing skills run as isolated sub-tasks
- Manages its own configuration. Tell it to add an API key or install a skill, and it handles the file edits and reloads itself
- Sends and receives email through its own inbox via AgentMail
- Copies to and pastes from your system clipboard, including images
- Accepts mid-task input. Press any key while it's working to type instructions. Ctrl-Q queues input for after the current step finishes
- Farms out grunt work to a cheaper model. Asks GPT-5.4 for a second opinion when stuck
- Saves full conversation threads so you can resume interrupted work
- Tracks token usage and dollar cost via OpenRouter, with Anthropic prompt caching for cost reduction

## Quick start

```bash
git clone https://github.com/fluffypony/dothething.git
cd dothething
./dtt.sh --prompt "Find the 10 largest public companies by revenue that went bankrupt in the last 20 years and write a markdown report with causes and timelines."
```

First run prompts for your OpenRouter API key (required) and a 2Captcha API key (optional), and saves them to `~/.dtt/env` (mode 0600). Subsequent runs read the keys from there. To skip the prompt, export `OPENROUTER_API_KEY` in your shell first; values in the shell environment take precedence over the saved file. To change or clear the saved keys, edit or delete `~/.dtt/env`.

The first run also takes a couple of minutes to set up a Python venv, install SearXNG, and set up the Notte browser framework. After that, startup is fast.

Omit `--prompt` to open a multiline editor. Type your task, then hit Esc+Enter to submit.

## Requirements

- macOS or Linux
- Python 3.11+
- An OpenRouter API key. Get one at [openrouter.ai/keys](https://openrouter.ai/keys). First run prompts for it and saves it to `~/.dtt/env`, or export `OPENROUTER_API_KEY` in your shell to skip the prompt.
- Optional: a 2Captcha API key for automated captcha solving during browser tasks. First-run setup prompts for this too, or export `TWOCAPTCHA_API_KEY`.
- Optional: an AgentMail API key for email tools. The agent can set this up for you on first use, or get one at [agentmail.to](https://agentmail.to).
- Linux clipboard/image support needs `wl-clipboard` (Wayland) or `xclip` (X11).

Everything else is installed automatically into `/tmp/dothething` on first run.

## Usage

```bash
./dtt.sh [flags]
```

| Flag | What it does |
|---|---|
| `--prompt "..."` | Provide the task inline instead of opening the editor |
| `--fast` | Use claude-opus-4.6-fast (cheaper, slightly less capable) |
| `--cwd DIR` | Set the working directory for file operations (default: `.`) |
| `--max-loops N` | Cap the number of agent turns (default: 200) |
| `--oraclepro` | Use GPT-5.4-pro instead of GPT-5.4 for oracle calls |
| `--resume ID` | Pick up a previous session by thread ID |
| `--headed` | Show the browser window for visual debugging |
| `--orchestrator` | Launch orchestrator mode -- run and manage multiple agents from one terminal |
| `--pipe` | Stdout-only output for Unix pipelines. Final report on stdout, everything else suppressed. Exit codes: 0=complete, 2=partial, 1=failed |
| `--tui` | Full-screen terminal UI for single-agent mode (experimental) |
| `--notify-desktop` | Send a desktop notification when the task finishes |
| `--notify-email EMAIL` | Email a notification to this address when the task finishes (requires AgentMail) |
| `--max-cost USD` | Stop and checkpoint when cumulative cost reaches this amount |
| `--verbose` | Show full error tracebacks |
| `--debug` | Log raw API payloads and cache metrics |

## How it works

The agent routes Claude Opus through OpenRouter. Every turn, the model decides which tools to call, processes the results, and decides what to do next.

**result_mode.** Every tool call has a `result_mode`. If you need exact output, use `"raw"`. If you tell it to "extract all function signatures", it pipes the output through Sonnet for a tight summary before the main agent sees it. This keeps the context window manageable on long tasks.

**Browser automation.** We use Notte with Camoufox under the hood. For simple scraping, `fetch_page` grabs clean markdown with no LLM cost. If a captcha shows up, it gets solved automatically. For complex multi-step interactions (login flows, forms, SPAs), the agent can hand off the session to a dedicated Notte browser agent via `browser_agent`.

**Prompt caching.** We use OpenRouter sticky routing and Anthropic's block-level cache controls. On long tasks, subsequent turns hit the cache, cutting input costs significantly.

**Thread persistence.** Every session saves to `~/.dtt/threads/` with a timestamped ID. If you interrupt a run or hit the loop limit, resume with `--resume <thread-id>`.

**Skills.** Drop skill directories into `~/.dtt/skills/` to teach the agent new procedures. Each skill is a directory containing a `SKILL.md` file (Claude Code convention). Skills with `allowed-tools` in their frontmatter inject directly into the agent's context, so it follows those instructions while using its own tools. Text-processing skills run via Sonnet as isolated sub-tasks. Skills can also be installed mid-session via the `manage_skill` tool.

**MCP servers.** Configure MCP servers in `~/.dtt/mcp.json` (same format as Claude Code). The agent picks up all connected MCP tools at startup. Servers can also be added mid-session via the `manage_mcp` tool.

## Orchestrator mode

`--orchestrator` opens a terminal UI for running multiple agents in parallel. You get:

- One line per session showing status, current phase, elapsed time, and cost
- Expand any session to watch its log in real time
- Send live input or queued input to a running agent
- Terminate, copy logs, or copy final output to your clipboard
- A "smart launcher" that sends your prompt to Opus, which figures out how to split the work and spins up agents for each piece

The smart launcher caps at 16 concurrent agents by default and shows a cost estimate before launching.

## Live input

While the agent is running, press any key to open an input bar at the bottom. Type and press Enter to inject your message immediately. Press Ctrl-Q to queue it until the current step finishes. Press Esc to cancel.

The agent can also ask you questions directly when it needs something it can't figure out on its own -- an OTP code, a preference, or confirmation before a destructive action.

## Email

DTT can send and receive email through AgentMail. First time: the agent signs itself up, you confirm a one-time OTP from your personal email, and the API key is saved for all future sessions. After that, it handles email on its own.

Set `AGENTMAIL_API_KEY` in your shell or let the agent create one via `email_auth`.

## Models

All calls route through OpenRouter. You only need one API key.

| Role | Default model | Flag to change |
|---|---|---|
| Main agent | Claude Opus 4.6 | `--fast` for Opus 4.6-fast |
| Summarizer, Notte agent, delegate | Claude Sonnet 4.6 | -- |
| Oracle | GPT-5.4 | `--oraclepro` for GPT-5.4-pro |

## Tools

**File operations:** `read_file`, `write_file`, `edit_file`, `batch_read`, `diff_files`

**System:** `run_command`, `shell_session`, `run_code`, `glob`, `list_dir`, `search_file`, `clipboard_copy`, `clipboard_paste`, `request_user_input`

**Web:** `search_web` (hybrid Serper + SearXNG for general discovery, plus engine/category targeting), `fetch_page` (Notte-powered scraping), `browser_agent` (full interactive control), `http_request`

**Analysis:** `think`, `oracle`, `delegate`, `analyze_data`, `analyze_image`, `batch_process`

**State:** `notes_add`, `notes_read`, `plan_create`, `plan_update`

**Config:** `manage_config`, `manage_skill`, `manage_mcp`

**Email:** `email_auth`, `email_list_inboxes`, `email_create_inbox`, `email_list`, `email_read`, `email_send`, `email_delete`, `email_wait_for_message`

**Extensions:** `use_skill` (custom skills), MCP tools (from configured servers)

## Skills

Each skill lives in its own directory under `~/.dtt/skills/` as a `SKILL.md` file (matching Claude Code's convention). So a skill called `my-skill` would live at `~/.dtt/skills/my-skill/SKILL.md`. Subdirectories are scanned recursively, so you can organize skills however you like. Each `SKILL.md` can have optional YAML frontmatter:

```yaml
---
name: my-skill
description: What this skill does
inline: true          # inject into agent context (vs. delegate to Sonnet)
allowed-tools: [Read, Write, Edit]  # implies inline
disable-model-invocation: true  # hide from agent's skill list
---

Your skill instructions here...
```

Skills with `allowed-tools` or `inline: true` get injected directly into the agent's system prompt. The agent applies them while working, using its full tool access. All other skills are available via the `use_skill` tool for isolated execution.

## MCP servers

Configure MCP servers in `~/.dtt/mcp.json`:

```json
{
  "mcpServers": {
    "my-server": {
      "command": "npx",
      "args": ["-y", "my-mcp-server"],
      "env": { "API_KEY": "${MY_API_KEY}" }
    }
  }
}
```

The agent discovers and uses all tools exposed by connected MCP servers.

## Environment variables

| Variable | Required | Description |
|---|---|---|
| `OPENROUTER_API_KEY` | Yes | Your OpenRouter API key |
| `SERPER_API_KEY` | No | Enables hybrid `search_web` plus Serper-backed `batch_process` search enrichment |
| `TWOCAPTCHA_API_KEY` | No | Enables automated captcha solving |
| `AGENTMAIL_API_KEY` | No | AgentMail key for email tools |
| `AGENTMAIL_INBOX_ID` | No | Default AgentMail inbox ID |
| `AGENTMAIL_HUMAN_EMAIL` | No | Human email for AgentMail OTP verification |

All variables can be saved to `~/.dtt/env` (shell-exported values take precedence). The agent can update this file via `manage_config`.

## Where things live

| Path | What's there |
|---|---|
| `~/.dtt/env` | Saved API keys for OpenRouter, Serper, 2Captcha, and AgentMail. Mode 0600. The agent can update this via manage_config. |
| `~/.dtt/threads/` | Saved conversation threads (resume with `--resume`) |
| `~/.dtt/threads/<id>/cache/` | Per-thread scratch folder (intermediate files, downloads, batch artifacts) |
| `~/.dtt/skills/<name>/SKILL.md` | User-defined skills (Claude Code convention) |
| `~/.dtt/mcp.json` | MCP server configuration |
| `/tmp/dothething/` | Runtime: Python venv, SearXNG, Camoufox browser |

## Pipe mode

`--pipe` sends only the final report to stdout and mutes everything else. Use it when you need to chain dothething into other commands:

```bash
./dtt.sh --pipe --prompt "Summarize the README in this repo" | pbcopy
./dtt.sh --pipe --prompt "List all TODO comments" > todos.txt
cat spec.md | ./dtt.sh --pipe --prompt "Review this spec"
```

Exit codes: 0 means complete, 2 means partial, 1 means failed.

## Notifications

`--notify-desktop` pops a system notification when the task finishes. On macOS this uses osascript, on Linux it uses notify-send.

`--notify-email you@example.com` sends a short email summary when done. Requires AgentMail to be configured.

Both work in orchestrator mode -- you get per-agent notifications as they finish, plus one when all agents are done.

## Persistent shell

The `shell_session` tool provides a stateful bash session that persists environment variables, working directory, and shell state across calls. Use it for multi-step build processes, interactive debugging, or anything where shell state matters between commands. For simple one-off commands, `run_command` is still there and simpler.

## Cost limits

`--max-cost 5.00` stops the agent when cumulative spending hits $5. The agent checkpoints its state so you can `--resume` later if you want to continue. Useful for fire-and-forget runs where you don't want to babysit the budget.

## Email polling

`email_wait_for_message` pauses the agent until a specific reply hits the inbox. Set filters on sender, subject, or thread. The agent polls every few seconds and returns the message when it arrives, or times out. Saves you from wasting tokens on manual poll loops.

## Security

Persisted thread logs (`~/.dtt/threads/`) are redacted -- API keys, tokens, and secrets are masked before writing to disk. The same redaction applies to `--debug` output.

## License

BSD 3-Clause. See [LICENSE](LICENSE) for the full text.
