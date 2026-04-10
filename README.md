# dothething

**An autonomous AI agent: You describe the thing. It does the thing.**

Dothething (DTT) is an autonomous AI agent that runs locally, thinks for itself, and gets stuff done. Give it a task, walk away, come back to results.

It searches the web, reads and writes files, runs shell commands, browses pages with a real browser, and keeps working until the job is finished - or tells you why it couldn't.

**Website:** [dotheth.ing](https://dotheth.ing)

## What it does

You describe a task in plain language. The agent breaks it into steps, executes them, and delivers the output. It's not just a coding tool - it handles research, analysis, report writing, data extraction, document processing, system administration, and anything else you'd do at a terminal with a browser open.

The agent:

- Plans its own work and tracks progress
- Searches the web via a local SearXNG instance (no API keys for search)
- Browses pages with Camoufox (a stealth Firefox fork) and extracts content with Readability.js
- Reads and edits files, runs shell commands, makes HTTP requests
- Delegates mechanical sub-tasks to a cheaper model to save money
- Consults GPT-5.4 as an "oracle" when it gets stuck on hard problems
- Saves full conversation threads so you can resume interrupted work
- Tracks costs per model across the session

## Quick start

```bash
git clone https://github.com/fluffypony/dothething.git
cd dothething
export OPENROUTER_API_KEY="your-key-here"
./dtt.sh --prompt "Find the 10 largest public companies by revenue that went bankrupt in the last 20 years and write a markdown report with causes and timelines"
```

First run takes a couple minutes - it sets up a Python venv, installs SearXNG, downloads Camoufox, and grabs Readability.js. After that, startup is fast.

If you omit `--prompt`, it opens a multiline editor. Type your task, then hit Esc+Enter (or Ctrl+D) to submit.

## Requirements

- Python 3
- Git
- An [OpenRouter](https://openrouter.ai/) API key (set as `OPENROUTER_API_KEY`)

Everything else is installed automatically into `/tmp/dothething` on first run.

## Usage

```
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
| `--verbose` | Show full error tracebacks |
| `--debug` | Log raw API payloads |
| `--keep-temp` | Don't clean up `/tmp/dothething` on exit |

## How it works

The agent runs Claude Opus through OpenRouter with a set of tools - file I/O, shell execution, web search, browser fetching, image analysis, and more. Each turn, the model decides which tools to call (often several in parallel), processes the results, and decides what to do next.

A few things worth knowing:

**result_mode.** Every tool call includes a `result_mode` parameter. Set it to `"raw"` for exact output, or pass a goal string like `"extract all function signatures and their docstrings"` - the output gets piped through Sonnet for a focused summary before the agent sees it. This is how it manages context on long tasks without drowning in output.

**Planning.** The agent creates a numbered plan at the start of every task and marks items complete as it goes. If scope changes mid-task, it adds or removes steps. You can see the plan evolving in the stderr output.

**Thread persistence.** Every session is saved to `~/.dtt/threads/` with a timestamped ID. If you interrupt a run or it hits the loop limit, you can resume with `--resume <thread-id>`. The thread ID is printed at the end of every session.

**Cost tracking.** The agent fetches cost data from OpenRouter's generation stats API after each call. At the end of the session, it prints a breakdown by model - tokens in, tokens out, reasoning tokens, cached tokens, and dollar cost.

**Stagnation detection.** If the agent repeats the same tool calls three turns in a row, it gets a nudge to try a different approach. If it refuses to use tools at all for three turns, the session stops.

## Models

| Role | Default model | Flag to change |
|---|---|---|
| Main agent | Claude Opus 4.6 | `--fast` for Opus 4.6-fast |
| Summarizer & delegate | Claude Sonnet 4.6 | - |
| Oracle | GPT-5.4 | `--oraclepro` for GPT-5.4-pro |

All calls go through OpenRouter, so you need one API key regardless of which underlying providers are used.

## Tools the agent has access to

- **read_file / write_file / edit_file / batch_read / diff_files** - File operations with line numbers, partial reads, search/replace editing, regex mode, and document parsing (PDF, DOCX, XLSX, CSV)
- **glob / list_dir / search_file** - Find files by name or content (uses ripgrep when available)
- **run_command** - Shell execution with timeout, stdin, and environment variables
- **search_web** - Local SearXNG search with categories and time filtering
- **fetch_page** - Browser-based page fetching with Readability.js extraction, screenshots, or lightweight text mode
- **http_request** - Direct HTTP for REST APIs, downloads, webhooks
- **analyze_image** - Vision analysis via Sonnet for screenshots, charts, diagrams
- **notes_add / notes_read / notes_clear** - Persistent scratchpad that survives context pressure
- **delegate** - Farm out mechanical sub-tasks to Sonnet (no tool access, text-in text-out)
- **oracle** - Ask GPT-5.4 for a second opinion on hard problems
- **plan_create / plan_remaining / plan_completed / plan_update** - Task planning and progress tracking
- **think** - Free-form reasoning scratchpad (no API cost)
- **finalize** - End the task and present results

## Examples

Research task:
```bash
./dtt.sh --prompt "Compare the mass transit systems of Tokyo, London, and New York. Write a report covering ridership, coverage area, cost per ride, and age of infrastructure. Save to transit_comparison.md"
```

Data extraction:
```bash
./dtt.sh --cwd ./my-project --prompt "Find every API endpoint in this codebase and output them as a JSON file with method, path, handler, and auth requirements"
```

Analysis:
```bash
./dtt.sh --prompt "Download the CSV from https://example.com/data.csv, find the top 10 customers by lifetime revenue, and write the results to a markdown table"
```

Resuming an interrupted session:
```bash
./dtt.sh --resume 20260115-143022-a1b2c3d4
```

## Where things live

| Path | Contents |
|---|---|
| `/tmp/dothething/` | Runtime: Python venvs, SearXNG, Camoufox browser, Readability.js |
| `~/.dtt/threads/` | Saved conversation threads (messages.json + meta.json per thread) |

The `/tmp` directory gets recreated if missing. Thread history persists across runs.

## License

BSD 3-Clause. See [LICENSE](LICENSE) for the full text.