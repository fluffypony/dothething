# dothething

Dothething (DTT) is a local AI agent. You give it a task, walk away, and come back to results.

It handles research, data extraction, browser automation, file editing, and code execution. It works until the job is done, or tells you exactly why it couldn't.

**Website:** [dotheth.ing](https://dotheth.ing)

## What it does

You describe a task in plain English. The agent breaks it down, picks the right tools, and delivers the output.

- Plans its work and tracks progress
- Searches the web using a local SearXNG instance. The general-web engines fetch through a real browser, so Google and friends actually answer instead of serving a bot wall; primary-source APIs (OpenAlex, Crossref, PubMed, arXiv) are queried directly and weighted above general web hits
- Browses pages with Notte and Camoufox (a Firefox fork built to avoid fingerprinting). Extracts page content, solves captchas, and handles multi-step web interactions
- Reads and edits files, runs shell commands, makes HTTP requests
- Connects to your existing MCP servers via `~/.dtt/mcp.json`
- Loads custom skills from `~/.dtt/skills/<skill-name>/SKILL.md` (Claude Code convention). Only names and descriptions sit in context; the agent loads a skill's full instructions on demand when a task matches
- Manages its own configuration. Tell it to add an API key or install a skill, and it handles the file edits and reloads itself
- Sends and receives email through its own inbox via AgentMail
- Copies to and pastes from your system clipboard, including images
- Accepts mid-task input. Press any key while it's working to type instructions. Ctrl-Q queues input for after the current step finishes
- Farms out grunt work to a cheaper model, and asks a stronger one for a second opinion when it's stuck
- Saves full conversation threads so you can resume interrupted work
- Tracks token usage and dollar cost via OpenRouter, with Anthropic prompt caching for cost reduction

## Quick start

```bash
curl -fsSL dotheth.ing/dtt.sh | bash -s -- --install
dtt --prompt "Find the 10 largest public companies by revenue that went bankrupt in the last 20 years and write a markdown report with causes and timelines."
```

`--install` puts the script in `~/.local/bin/dtt` and adds that directory to your PATH if it isn't there already (macOS has it by default, most Linux distros don't). It is the same script either way, so if you'd rather clone the repo, `git clone https://github.com/fluffypony/dothething.git && ./dtt.sh --install` gets you to the same place, and `./dtt.sh` runs fine without installing at all.

First run prompts for your OpenRouter API key (required) and a 2Captcha API key (optional), and saves them to `~/.dtt/env` (mode 0600). Subsequent runs read the keys from there. To skip the prompt, export `OPENROUTER_API_KEY` in your shell first; values in the shell environment take precedence over the saved file. To change or clear the saved keys, edit or delete `~/.dtt/env`.

The first run also takes a couple of minutes to set up a Python venv, install SearXNG, and set up the Notte browser framework. After that, startup is fast.

Omit `--prompt` to open a multiline editor. Type your task, then hit Esc+Enter to submit.

## Modes

dtt has three modes. **Normal** is the default: cheap, fast models (DeepSeek V4 Flash for the agent, Gemini Flash for the worker, Claude Sonnet for the browser, GPT-5.6 Terra for the oracle) at `xhigh` reasoning, with the full toolset. It handles most work.

```bash
dtt "research the 10 largest data breaches of 2025 and summarise the causes"
```

**Advanced** (`--advanced`) swaps in the strongest models (Claude Fable 5 plus the GPT-5.6 Sol oracle) at `max` reasoning. Reach for it on genuinely hard tasks; it is slower and costs more.

```bash
dtt --advanced "audit this codebase for concurrency bugs and propose fixes"
```

**Quick** (`q`, or `-q`/`--quick`) is for a fast answer, not a research project. It one-shots on a fast frontier model (Claude Opus 5 Fast), with a trimmed toolset: no oracle, no plan or notes bookkeeping, no batch machinery, and skills stay out of the prompt until invoked. Its first reply stacks every tool call the job needs, staged with `exec_order` where order matters, and the next reply is the answer. The loop cap drops to 15 turns.

```bash
dtt q "what's the weather like in Cape Town today"
dtt q "create an SSH key for me and copy it to clipboard"
```

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
| `q` (or `-q`, `--quick`) | Quick mode: one-shot on a fast frontier model with a trimmed toolset and no oracle |
| `--advanced` | Advanced mode: strongest models (Fable + GPT-5.6 Sol) at max reasoning, for hard tasks |
| `--prompt "..."` | Provide the task inline instead of opening the editor |
| `--cwd DIR` | Set the working directory for file operations (default: `.`) |
| `--max-loops N` | Cap the number of agent turns (default: 200; 15 in quick mode) |
| `--model [ROLE=]SLUG` | Override the model for a role: `main`, `worker`, `oracle`, or `browser`. Repeatable. A bare slug targets `main`; `ROLE=default` clears a saved or env override |
| `--resume ID` | Pick up a previous session by thread ID. Inherits that thread's saved config (model, oracle, `--max-loops`, `--cwd`); pass a flag to override it |
| `--headed` | Show the browser window for visual debugging |
| `--orchestrator` | Launch orchestrator mode -- run and manage multiple agents from one terminal |
| `--pipe` | Stdout-only output for Unix pipelines. Final report on stdout, everything else suppressed. Exit codes: 0=complete, 2=partial, 1=failed |
| `--tui` | Full-screen terminal UI for single-agent mode (experimental) |
| `--notify-desktop` | Send a desktop notification when the task finishes |
| `--notify-email EMAIL` | Email a notification to this address when the task finishes (requires AgentMail) |
| `--max-cost USD` | Stop and checkpoint when cumulative cost reaches this amount |
| `--verbose` | Show full error tracebacks |
| `--debug` | Log raw API payloads and cache metrics |
| `--install` | Install the script to `~/.local/bin/dtt`, adding that directory to your PATH if needed |
| `--update` | Force an update check, bypassing the 6-hour rate limit |
| `--browsermcp` | Run a stdio MCP server exposing dtt's search + browser tools to another agent |

## How it works

Every model call routes through OpenRouter. Each turn, the agent decides which tools to call, reads the results, and decides what to do next. It keeps going until the task is done or it hits the loop or cost limit.

**result_mode.** Every tool call has a `result_mode`. If you need exact output, use `"raw"`. If you tell it to "extract all function signatures", it pipes the output through the worker model for a tight summary before the main agent sees it. This keeps the context window manageable on long tasks.

**Stacked tool calls with exec_order.** The agent can return many tool calls in a single reply. By default they all run in parallel. An optional `exec_order` field on each call sequences them into stages: calls sharing a stage number run concurrently, and the next stage starts once the previous one finishes. Seven calls staged `1,1,2,3,3,3,4` run as two in parallel, then one, then three in parallel, then one. If every call in a stage fails, the later stages are skipped so the agent can correct course. "Make a directory, write three files into it, list the result" completes in one round-trip instead of three.

**Browser automation.** We use Notte with Camoufox under the hood. For simple scraping, `fetch_page` grabs clean markdown with no LLM cost. If a captcha shows up, it gets solved automatically. For complex multi-step interactions (login flows, forms, SPAs), the agent can hand off the session to a dedicated Notte browser agent via `browser_agent`.

**Search runs through the browser.** SearXNG fetches with a plain HTTP client: no JS, no browser TLS fingerprint, no captcha handling. Google now answers that client with a "please enable JavaScript" stub containing no results at all, so a stock SearXNG install quietly returns nothing for its most important engine while still listing it as configured.

So the general-web engines don't fetch their own pages any more. A bridge engine hands the search URL to a pool of Camoufox sessions, which issue the request from inside a real page and hand back the response body. URL building and parsing stay with SearXNG's own engine modules, so upstream's parser fixes arrive with the weekly SearXNG update instead of being reimplemented here; where a SERP's markup has drifted far enough that upstream's selectors match nothing, a generic extractor pulls titles and links rather than dropping the result set.

Two lanes, set by `SEARXNG_NOTTE_ENGINES` and `SEARXNG_DIRECT_ENGINES` near the top of `dtt.sh`:

- **Browser lane.** Google, Google Scholar, Bing, DDG, Brave, Startpage, Yep, Yahoo. Correct but slow; a search costs roughly `ceil(engines / sessions)` browser round-trips. `DTT_NOTTE_SERP_SESSIONS` (default 4) sets the pool size, trading about 500MB per session against search latency. Each engine also declares how it should be fetched: most want `fetch`, which returns the response body their parser expects, while Google only serves real results to a `navigate` and hands a fetch the same stub it gives a plain HTTP client.
- **Direct lane.** OpenAlex, Crossref, PubMed, arXiv, OpenAIRE, Mwmbl, Wikipedia, the package registries, the forum and Q&A engines. Public APIs and structured records with no bot protection, weighted 2.0–3.0 so primary sources outrank general web hits. A browser here would add twenty seconds and buy nothing.

Three engines are deliberately absent. Qwant's API answers 403 to everything, browser or not. Mojeek sits behind an ALTCHA challenge that needs a human click. Google News links results through relative `./read/` redirects rather than real URLs. Wikidata is out too: its SPARQL preflight only works with a contact User-Agent (hence `useragent_suffix`), and even once it starts it returns nothing, while Wikipedia answers the same queries.

The config also drops the old `keep_only` list, which had pruned all ~330 other engines and left `!bang` syntax pointing at engines that no longer existed, and sets `default_lang: all` because `en` was silently discarding non-English primary sources. `oa_doi_rewrite` sends paywalled DOIs to an open-access copy, and the `hostnames` plugin demotes the SEO/AI-listicle hosts that now crowd general SERPs.

**Prompt caching.** We use OpenRouter sticky routing and Anthropic's block-level cache controls. On long tasks, subsequent turns hit the cache, cutting input costs significantly.

**Thread persistence.** Every session saves to `~/.dtt/threads/` with a timestamped ID. If you interrupt a run or hit the loop limit, resume with `--resume <thread-id>`.

**Skills.** Drop skill directories into `~/.dtt/skills/` to teach the agent new procedures. Each skill is a directory containing a `SKILL.md` file (Claude Code convention). Loading is progressive: only names and descriptions stay in the prompt, and the agent reads a skill's full instructions with `use_skill` when a task matches its description. A skill with `allowed-tools` runs in the agent's own context so it can use those tools; one without runs as an isolated worker-model sub-task. Skills can also be installed mid-session via the `manage_skill` tool.

**MCP servers.** Configure MCP servers in `~/.dtt/mcp.json` (same format as Claude Code). The agent picks up all connected MCP tools at startup. Servers can also be added mid-session via the `manage_mcp` tool.

**Computer use (macOS).** On macOS, dtt gains a `computer_use` tool that drives the screen, keyboard, and mouse through [Peekaboo](https://github.com/openclaw/Peekaboo). It bundles Peekaboo itself, downloading the pinned universal binary into `~/.dtt/cache` on first run, so you don't need Homebrew (if you already have `peekaboo` on your PATH, dtt uses that instead). The agent works by screenshotting the screen, reading the element map, and clicking or typing by element label. Peekaboo's LLM verbs (`agent`, `analyze`) are left out, since dtt is already the model.

Two macOS permissions are required, and macOS attributes both to the app that launched dtt, not to dtt or python: **Screen Recording** (for screenshots) and **Accessibility** (for clicking and typing). Grant them to your terminal in System Settings > Privacy & Security, then restart the terminal. dtt cannot set these for you; if a `computer_use` call reports a missing grant, it names which one and where. Actions that only read the accessibility tree or type text work with Accessibility alone; only screenshots need Screen Recording.

## Orchestrator mode

`--orchestrator` opens a terminal UI for running multiple agents in parallel. You get:

- One line per session showing status, current phase, elapsed time, and cost
- Expand any session to watch its log in real time
- Send live input or queued input to a running agent
- Terminate, copy logs, or copy final output to your clipboard
- A "smart launcher" that sends your prompt to Fable, which figures out how to split the work and spins up agents for each piece

The smart launcher caps at 16 concurrent agents by default and shows a cost estimate before launching.

## Live input

While the agent is running, press any key to open an input bar at the bottom. Type and press Enter to inject your message immediately. Press Ctrl-Q to queue it until the current step finishes. Press Esc to cancel.

The agent can also ask you questions directly when it needs something it can't figure out on its own -- an OTP code, a preference, or confirmation before a destructive action.

## Email

DTT can send and receive email through AgentMail. First time: the agent signs itself up, you confirm a one-time OTP from your personal email, and the API key is saved for all future sessions. After that, it handles email on its own.

Set `AGENTMAIL_API_KEY` in your shell or let the agent create one via `email_auth`.

## Models

All calls route through OpenRouter. You only need one API key. The default slugs live in [models.txt](https://dotheth.ing/models.txt); dtt fetches that file once a day, so defaults can change without a release. Your `--model` flags and `DTT_MODEL_*` env vars always win over it.

| Role | Normal (default) | Advanced (`--advanced`) |
|---|---|---|
| Main agent (`main`) | DeepSeek V4 Flash | Claude Fable 5 |
| Worker: summaries, analysis, delegation (`worker`) | Gemini Flash | Gemini Flash |
| Browser agent, Notte (`browser`) | Claude Sonnet | Claude Fable 5 |
| Oracle (`oracle`) | GPT-5.6 Terra | GPT-5.6 Sol |
| Perception (Notte vision) | Gemini Flash | Gemini Flash |

Quick mode (`q`) runs the agent on Claude Opus 5 Fast with no oracle. Any role is overridable with `--model role=slug` or `DTT_MODEL_*`.

### Reasoning effort

The main agent's reasoning effort tracks the mode: normal runs `xhigh`, advanced runs `max` (the top of OpenRouter's scale), and quick drops to `medium`, which is most of where its speed comes from. The oracle always runs `max`: it is only called on problems the agent is already stuck on, so the extra thinking is cheap at that call volume.

### Model overrides

Any of the four roles can be swapped for a different OpenRouter model with `--model`:

```bash
dtt --model oracle=x-ai/grok-5 "..."                         # different oracle
dtt --model worker=google/gemini-flash-lite-latest "..."     # cheaper worker
dtt --model anthropic/claude-opus-5 "..."                    # bare slug targets main
dtt --model main=openai/gpt-5.6-sol --model browser=~anthropic/claude-sonnet-latest "..."
```

`--model` beats the mode defaults. A resumed thread keeps its overrides unless you pass new ones, and `--model oracle=default` clears one. To make an override permanent, set `DTT_MODEL_MAIN`, `DTT_MODEL_WORKER`, `DTT_MODEL_ORACLE`, or `DTT_MODEL_BROWSER` in `~/.dtt/env`; CLI flags win over env vars. Orchestrator workers inherit whatever overrides are in effect.

## Tools

**File operations:** `read_file`, `write_file`, `edit_file`, `batch_read`, `diff_files`

`edit_file` applies an ordered array of exact `old_text`/`new_text` replacements. It validates the full array before it writes, rejects ambiguous matches by default, and returns the applied diff. `read_file` includes a SHA-256 value that `edit_file` can use to reject stale edits.

**System:** `run_command`, `shell_session`, `run_code`, `glob`, `list_dir`, `search_file`, `clipboard_copy`, `clipboard_paste`, `computer_use` (macOS GUI control via Peekaboo), `request_user_input`

**Web:** `search_web` (hybrid Serper + SearXNG for general discovery, plus engine/category targeting; general-web engines fetch through Notte), `fetch_page` (Notte-powered scraping), `browser_agent` (full interactive control), `http_request`

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
description: What this skill does, and when to use it
allowed-tools: [Read, Write, Edit]  # optional: skill needs these tools when it runs
disable-model-invocation: true      # optional: hide from the agent's skill list
---

Your skill instructions here...
```

Skills load on demand, following Anthropic's Agent Skills model. Only each skill's `name` and `description` sit in the system prompt, so a large skill library costs almost nothing until it's used. The `description` is the trigger: write it to say both what the skill does and when to reach for it, because that's what the agent matches against. When a task fits, the agent calls `use_skill` to pull the full instructions. A skill that declares `allowed-tools` runs in the agent's own context so it can read and write files; a skill without them runs as an isolated worker-model sub-task.

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
| `DTT_MODEL_MAIN` | No | Default model override for the main agent |
| `DTT_MODEL_WORKER` | No | Default model override for the worker (summaries, delegation, batch) |
| `DTT_MODEL_ORACLE` | No | Default model override for the oracle |
| `DTT_MODEL_BROWSER` | No | Default model override for the Notte browser agent |
| `SERPER_API_KEY` | No | Enables hybrid `search_web` plus Serper-backed `batch_process` search enrichment |
| `TWOCAPTCHA_API_KEY` | No | Enables automated captcha solving |
| `AGENTMAIL_API_KEY` | No | AgentMail key for email tools |
| `AGENTMAIL_INBOX_ID` | No | Default AgentMail inbox ID |
| `AGENTMAIL_HUMAN_EMAIL` | No | Human email for AgentMail OTP verification |
| `DTT_NOTTE_SERP_SESSIONS` | No | Browser sessions backing the search bridge (default 4, max 8). More sessions means faster searches and about 500MB of memory each |

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
