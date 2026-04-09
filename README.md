# dothething

A terminal agent that keeps going until the job is done. Give it a task, walk away, come back to results.

It talks to [OpenRouter](https://openrouter.ai), defaults to `anthropic/claude-opus-4.6`, and has unrestricted access to your filesystem, shell, and the internet. There is no approval step. It will just do the thing.

```
./dothething.sh --prompt "Find the bug in src/, fix it, and make sure the tests pass."
```

## Why this exists

I wanted an agent I could point at a codebase and forget about. Not a chatbot that asks me seventeen clarifying questions. Not something that stops after one tool call and waits for permission. Just: here's the task, go figure it out, tell me when you're done.

dothething boots its own environment, starts its own search engine, launches its own browser, and loops until it calls `finalize`. It reads whatever files it wants, runs your test suite if it thinks it should, and will SearXNG something if it gets confused. You get a final report and a cost summary at the end.

## What it can do

The agent has 14 tools:

**Files:** `read_file`, `write_file`, `edit_file`, `glob`, `search_file`

**Shell:** `run_command` (arbitrary bash, no restrictions)

**Web:** `search_web` (private SearXNG instance), `fetch_page` (Camoufox headless browser with Readability.js)

**Planning:** `plan_create`, `plan_remaining`, `plan_completed`

**Thinking:** `think` (free scratchpad), `oracle` (asks GPT-5.4 for a second opinion)

**Control:** `finalize` (done, here's the report)

## The context window trick

Opus has a 1M token context window, which is huge but not infinite. dothething avoids poisoning it with a simple rule: every tool call has a mandatory `result_mode` parameter.

If `result_mode` is `"raw"`, the full output goes into context unchanged. The agent is told to use this sparingly.

If `result_mode` is anything else, it's treated as a goal string. The raw output gets sent to Claude Sonnet 4.6, which compacts it into a summary focused on that goal. So instead of dumping 50,000 lines of test output into context, the agent says `result_mode: "which tests failed and why"` and gets back a few paragraphs.

The upshot: it can read a 10,000-line file or fetch a bloated web page and the context window barely notices.

## Install and run

You need `python3`, `git`, and an `OPENROUTER_API_KEY` environment variable. That's it. Everything else is bootstrapped on first run (takes a couple minutes the first time for SearXNG and Camoufox).

```bash
export OPENROUTER_API_KEY=sk-or-...

# Interactive prompt editor (Esc+Enter to submit)
./dothething.sh

# Inline prompt
./dothething.sh --prompt "Audit this repo for security issues and write a report."

# Pipe a prompt
echo "Refactor the database layer to use connection pooling." | ./dothething.sh

# Use the fast model
./dothething.sh --fast --prompt "Add type hints to every Python file in src/"
```

## Flags

```
--fast              Use anthropic/claude-opus-4.6-fast
--oraclepro         Use openai/gpt-5.4-pro for the oracle (default: openai/gpt-5.4)
--prompt "..."      Provide task inline instead of the editor
--cwd DIR           Working directory for relative paths (default: .)
--max-loops N       Maximum agent loop iterations (default: 200)
--resume THREAD_ID  Resume a previous run (see below)
--verbose           Verbose error traces
--debug             Log full API payloads to stderr
--keep-temp         Don't delete the /tmp/dothething runtime dir on exit
```

## Thread persistence and resume

Every run is saved to `~/.dtt/threads/<id>/`. The thread ID is printed at both the start and end of each run. If the agent gets interrupted (Ctrl+C, SSH drops, your cat walks on the keyboard), you can pick up where it left off:

```bash
./dothething.sh --resume 20260409-143022-a1b2c3d4
```

The resumed session loads the full message history, refreshes the system prompt, and nudges the agent to check its plan and keep going.

## How edit_file works

The agent has three ways to edit files, because LLMs are surprisingly bad at getting diffs right on the first try:

**search_replace** is the most reliable. The agent provides `<<<<<<< SEARCH` / `=======` / `>>>>>>> REPLACE` blocks with the exact text to find and what to replace it with. The search text must match uniquely.

**regex** is Python `re.sub` with flags. Good for mechanical changes across a file.

**unified_diff** is standard patch format. Works but the agent sometimes gets the context lines wrong, so search_replace is usually better.

## The oracle

Sometimes the agent gets stuck or faces a design decision where a second opinion would help. The `oracle` tool sends a question to GPT-5.4 (or GPT-5.4-pro with `--oraclepro`). It can optionally include the full conversation context so the oracle has the same picture the agent does.

It's expensive. The agent is told to use it only when it's genuinely useful, not as a crutch.

## Web access

dothething starts its own SearXNG instance on a random local port. No Docker, no external service, just a Python process that gets killed on exit. The agent searches through it and gets JSON results back.

For fetching actual pages, it uses Camoufox (a stealth Firefox fork) through Playwright. Three modes:

- **markdown**: injects Mozilla's Readability.js into the rendered page, extracts the article content, converts to markdown. This is how Firefox Reader Mode works under the hood. Falls back to stripping scripts/nav/etc. and converting what's left.
- **screenshot**: saves a PNG. Can capture above the fold, below the fold, or the full page.
- **html**: returns the final rendered DOM after all JavaScript has run.

## Cost tracking

Every OpenRouter API call gets its generation ID queued for stats lookup. A background worker fetches cost and token data from OpenRouter's `/generation` endpoint, retrying if the stats aren't available yet (they usually take a second or two to show up). When the agent finishes, it drains the queue and prints a breakdown by model:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Session cost: $1.2340
    anthropic/claude-opus-4.6: $1.0821, 3 calls, 847,291 in / 12,440 out
    anthropic/claude-sonnet-4.6: $0.1180, 8 calls, 142,500 in / 6,200 out
    openai/gpt-5.4: $0.0339, 1 call, 4,200 in / 1,800 out
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Opus at 1M context is not cheap. You'll want this visibility.

## What happens on first run

The bootstrapper creates a venv in `/tmp/dothething/`, installs dependencies, clones SearXNG into a separate venv (so its dependencies don't conflict), downloads the Camoufox browser binary, and grabs Readability.js from a CDN. Subsequent runs skip all of this.

If something gets corrupted, delete `/tmp/dothething/` and it'll rebuild from scratch.

## Things to know

**There is no sandbox.** The agent runs commands as your user. It can `rm -rf` things. It can `curl` things. It can rewrite your SSH config. Don't point it at anything you wouldn't trust a careless junior developer with sudo access to touch.

**The JSON fallback matters.** If OpenRouter's native tool-calling breaks (it sometimes does, depending on the model and provider), the agent falls back to parsing JSON tool calls from the model's text output. This is why the system prompt includes a JSON format spec. It's not elegant but it keeps things working when the API is flaky.

**Parallel tool calls are real.** When the agent requests multiple tools in one turn (read three files, run two commands), they all execute concurrently with `asyncio.gather`. On I/O-heavy turns this can cut wall time in half or better.

**The plan tools are not just decoration.** The system prompt tells the agent to start every task with `plan_create`. In practice this makes a noticeable difference in how methodically it works through multi-step problems versus yolo-ing tool calls and losing track of where it is.

## Project links

- GitHub: https://github.com/fluffypony/dothething
- Website: https://dotheth.ing

## License

BSD 3-Clause. See [LICENSE](LICENSE).