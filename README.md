# dothething

Dothething (DTT) is a local AI agent. You give it a task, walk away, and come back to results.

It handles research, data extraction, browser automation, file editing, and code execution. It works until the job is done, or tells you exactly why it couldn't.

**Website:** [dotheth.ing](https://dotheth.ing)

## What it does

You describe a task in plain English. The agent breaks it down, picks the right tools, and delivers the output.

- Plans its work and tracks progress
- Searches the web using a local SearXNG instance (supports Google, Bing, DuckDuckGo, and more -- you can target specific engines or search images directly)
- Browses pages with Notte and Camoufox (a stealth Firefox fork). Extracts clean content, solves captchas automatically, and handles complex multi-step web interactions
- Reads and edits files, runs shell commands, makes HTTP requests
- Connects to your existing MCP servers via `~/.dtt/mcp.json`
- Loads custom skills from `~/.dtt/skills/<skill-name>/SKILL.md` (Claude Code convention) -- behavioral skills inject directly into the agent's context, while text-processing skills run as isolated sub-tasks
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
- Docker (for SearXNG)
- An OpenRouter API key. Get one at [openrouter.ai/keys](https://openrouter.ai/keys). First run prompts for it and saves it to `~/.dtt/env`, or export `OPENROUTER_API_KEY` in your shell to skip the prompt.
- Optional: a 2Captcha API key for automated captcha solving during browser tasks. First-run setup prompts for this too, or export `TWOCAPTCHA_API_KEY`.

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
| `--verbose` | Show full error tracebacks |
| `--debug` | Log raw API payloads and cache metrics |

## How it works

The agent routes Claude Opus through OpenRouter. Every turn, the model decides which tools to call, processes the results, and decides what to do next.

**result_mode.** Every tool call has a `result_mode`. If you need exact output, use `"raw"`. If you tell it to "extract all function signatures", it pipes the output through Sonnet for a tight summary before the main agent sees it. This keeps the context window from blowing up on long tasks.

**Browser automation.** We use Notte with Camoufox under the hood. For simple scraping, `fetch_page` grabs clean markdown with no LLM cost. If a captcha shows up, it gets solved automatically. For complex multi-step interactions (login flows, forms, SPAs), the agent can hand off the session to a dedicated Notte browser agent via `browser_agent`.

**Prompt caching.** We use OpenRouter sticky routing and Anthropic's block-level cache controls. On long tasks, subsequent turns hit the cache, cutting input costs significantly.

**Thread persistence.** Every session saves to `~/.dtt/threads/` with a timestamped ID. If you interrupt a run or hit the loop limit, resume with `--resume <thread-id>`.

**Skills.** Drop skill directories into `~/.dtt/skills/` to teach the agent new procedures. Each skill is a directory containing a `SKILL.md` file (Claude Code convention). Skills with `allowed-tools` in their frontmatter inject directly into the agent's context, so it follows those instructions while using its own tools. Text-processing skills run via Sonnet as isolated sub-tasks.

**MCP servers.** Configure MCP servers in `~/.dtt/mcp.json` (same format as Claude Code). The agent picks up all connected MCP tools at startup.

## Models

All calls route through OpenRouter. You only need one API key.

| Role | Default model | Flag to change |
|---|---|---|
| Main agent | Claude Opus 4.6 | `--fast` for Opus 4.6-fast |
| Summarizer, Notte agent, delegate | Claude Sonnet 4.6 | -- |
| Oracle | GPT-5.4 | `--oraclepro` for GPT-5.4-pro |

## Tools

**File operations:** `read_file`, `write_file`, `edit_file`, `batch_read`, `diff_files`

**System:** `run_command`, `run_code`, `glob`, `list_dir`, `search_file`

**Web:** `search_web` (with engine/category targeting), `fetch_page` (Notte-powered scraping), `browser_agent` (full interactive control), `http_request`

**Analysis:** `think`, `oracle`, `delegate`, `analyze_data`, `analyze_image`, `batch_process`

**State:** `notes_add`, `notes_read`, `plan_create`, `plan_update`

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

## Where things live

| Path | What's there |
|---|---|
| `~/.dtt/env` | Saved OpenRouter + optional 2Captcha API keys (mode 0600). Edit or delete to reset. |
| `~/.dtt/threads/` | Saved conversation threads (resume with `--resume`) |
| `~/.dtt/threads/<id>/cache/` | Per-thread scratch folder (intermediate files, downloads, batch artifacts) |
| `~/.dtt/skills/<name>/SKILL.md` | User-defined skills (Claude Code convention) |
| `~/.dtt/mcp.json` | MCP server configuration |
| `/tmp/dothething/` | Runtime: Python venv, SearXNG, Camoufox browser |

## License

BSD 3-Clause. See [LICENSE](LICENSE) for the full text.
