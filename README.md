# dothething

**Autonomous AI agent - one shell script, zero config.**

[Website](https://dotheth.ing) · [GitHub](https://github.com/fluffypony/dothething) · [License](LICENSE)

---

dothething is a single Bash script that bootstraps a fully autonomous AI agent capable of research, analysis, report writing, file manipulation, shell execution, web browsing, and more. It sets up its own Python environment, installs its own dependencies, launches a local [SearXNG](https://github.com/searxng/searxng) instance for private web search, and fetches a [Camoufox](https://github.com/nickoala/camoufox) stealth browser - all into `/tmp/dothething`. No Docker, no Node, no global installs.

Give it a task. It makes a plan, executes it, and delivers results.

## Quick start

```bash
export OPENROUTER_API_KEY="sk-or-..."
./dtt.sh --prompt "Research the current state of solid-state batteries and write a report to batteries.md"
```

Or launch the interactive multiline editor (submit with `Esc+Enter`):

```bash
./dtt.sh
```

That's it. First run takes 1–2 minutes while it sets up SearXNG, Camoufox, and Python dependencies. Subsequent runs start in seconds.

## Requirements

- **Python 3** (3.9+)
- **Git**
- **An [OpenRouter](https://openrouter.ai/) API key** set as `OPENROUTER_API_KEY`
- Linux or macOS (anything with `/bin/bash`)

Everything else is installed automatically into `/tmp/dothething`.

## Usage

```
./dtt.sh [flags] [prompt ...]
```

### Flags

| Flag | Description |
|---|---|
| `--prompt "..."` | Provide the task inline |
| `--fast` | Use `claude-opus-4.6-fast` instead of `claude-opus-4.6` |
| `--oraclepro` | Use `gpt-5.4-pro` for the oracle tool (default: `gpt-5.4`) |
| `--cwd DIR` | Working directory for relative paths (default: `.`) |
| `--max-loops N` | Maximum agent loop iterations (default: 200) |
| `--resume ID` | Resume a previous thread by ID |
| `--verbose` | Verbose error traces |
| `--debug` | Log full API request/response payloads |
| `--keep-temp` | Don't clean up `/tmp/dothething` on exit |
| `-h`, `--help` | Show help and exit |

### Examples

```bash
# Research task
./dtt.sh --prompt "Find the top 10 YC companies by valuation and write a CSV"

# Work in a specific directory
./dtt.sh --cwd ~/projects/myapp --prompt "Add comprehensive error handling to all API routes"

# Resume a previous session
./dtt.sh --resume 20260115-143022-a1b2c3d4

# Pipe a prompt from a file
./dtt.sh < task.txt

# Use the faster (cheaper) model
./dtt.sh --fast --prompt "Summarize all markdown files in docs/"
```

## What it can do

dothething is not just a coding agent. It handles any task you can describe:

- **Research and analysis** - web search, page fetching, cross-referencing sources, writing reports with citations
- **File operations** - read, write, edit, diff, glob, batch read, search by name or content
- **Shell execution** - run any command, scripts, build tools, test suites
- **Data extraction** - parse PDFs, DOCX, XLSX, CSV; extract structured data into JSON/CSV/YAML
- **Web interaction** - stealth browser with Readability.js extraction, screenshots, cookie dismissal
- **Image analysis** - interpret screenshots, charts, diagrams, scanned documents via vision AI
- **API interaction** - make HTTP requests, download files, interact with REST endpoints
- **Delegation** - farm out mechanical sub-tasks (summarization, reformatting, classification) to a cheaper model

## How it works

1. **`dtt.sh`** creates a Python venv in `/tmp/dothething`, installs dependencies, clones and starts SearXNG, fetches the Camoufox browser binary and Readability.js, then launches the Python agent.

2. **The agent** connects to [OpenRouter](https://openrouter.ai/) and runs an autonomous loop: it receives a task, creates a plan, and iterates - calling tools, reading results, adjusting its approach - until the task is complete or it hits the loop limit.

3. **Models used:**
   - **Primary:** `claude-opus-4.6` (or `claude-opus-4.6-fast` with `--fast`)
   - **Summarizer/delegate/vision:** `claude-sonnet-4.6`
   - **Oracle (second opinion):** `gpt-5.4` (or `gpt-5.4-pro` with `--oraclepro`)

4. **Thread persistence:** every session is saved to `~/.dtt/threads/<id>/` with full message history and metadata. Resume any session with `--resume`.

## Tools

The agent has access to 22 tools:

| Tool | Purpose |
|---|---|
| `read_file` | Read files with line numbers; handles PDF, DOCX, XLSX, CSV |
| `write_file` | Write files with create-only safety mode |
| `edit_file` | Edit via search/replace, line range, insert, regex, or unified diff |
| `glob` | Find files by pattern |
| `search_file` | Search by filename or content (uses ripgrep) |
| `list_dir` | List directory contents with metadata |
| `batch_read` | Read multiple files in one call |
| `diff_files` | Compare two files |
| `run_command` | Execute shell commands |
| `search_web` | Private web search via local SearXNG |
| `fetch_page` | Fetch web pages as markdown, text, HTML, or screenshot |
| `http_request` | Direct HTTP requests for APIs and downloads |
| `analyze_image` | Vision AI for screenshots, charts, documents |
| `delegate` | Farm out sub-tasks to a fast, cheap model |
| `oracle` | Consult a separate frontier model for hard problems |
| `notes_add/read/clear` | Persistent working memory across turns |
| `plan_create/remaining/completed/update` | Structured task planning |
| `think` | Free-form reasoning scratchpad (zero cost) |
| `finalize` | End the task and present results |

Every tool call (except `finalize` and `think`) takes a `result_mode` parameter: set it to `"raw"` for exact output, or provide a goal string (e.g., `"extract all function signatures"`) to have the output summarized by Sonnet before it enters context. This is the primary lever for managing the context window on long tasks.

## Context and cost management

- **Summarization by default:** large tool outputs are summarized by Sonnet, keeping context lean. Use `result_mode="raw"` only when you need exact content.
- **Parallel execution:** independent tool calls in the same turn run concurrently.
- **Stagnation detection:** the agent is nudged if it repeats the same tool calls three turns in a row.
- **Context warnings:** the agent is alerted when approaching context window limits.
- **Cost tracking:** session cost is reported at the end, broken down by model, with token counts.

## Thread management

Sessions are persisted to `~/.dtt/threads/`:

```
~/.dtt/threads/
  20260115-143022-a1b2c3d4/
    messages.json    # Full conversation history
    meta.json        # Model, prompt, timestamps
```

Resume any session:

```bash
./dtt.sh --resume 20260115-143022-a1b2c3d4
```

List previous threads:

```bash
ls ~/.dtt/threads/
```

## Environment variables

| Variable | Required | Description |
|---|---|---|
| `OPENROUTER_API_KEY` | Yes | Your [OpenRouter](https://openrouter.ai/) API key |

## What gets installed where

Everything is self-contained:

| Location | Contents |
|---|---|
| `/tmp/dothething/venv/` | Main Python venv (agent dependencies) |
| `/tmp/dothething/searxng/` | SearXNG source clone |
| `/tmp/dothething/searxng_venv/` | Separate Python venv for SearXNG |
| `/tmp/dothething/Readability.js` | Mozilla Readability for article extraction |
| `/tmp/dothething/agent.py` | The generated agent script |
| `~/.dtt/threads/` | Persistent thread history |

Nothing is installed globally. Delete `/tmp/dothething` to reset everything.

## License

[BSD 3-Clause](LICENSE)