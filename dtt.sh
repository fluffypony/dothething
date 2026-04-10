#!/usr/bin/env bash
# dothething — Autonomous AI agent
# https://github.com/fluffypony/dothething | https://dotheth.ing
set -euo pipefail

BASE="/tmp/dothething"
VENV="$BASE/venv"

KEEP_TEMP=false
PASS_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --keep-temp)
      KEEP_TEMP=true
      ;;
    -h|--help)
      cat <<'HELP'
dothething — autonomous AI agent | https://dotheth.ing

Usage:
  ./dothething.sh [--fast] [--prompt "..."] [--cwd DIR] [--max-loops N]
                  [--oraclepro] [--verbose] [--debug] [--keep-temp]
                  [--resume THREAD_ID]

Flags:
  --fast          Use anthropic/claude-opus-4.6-fast instead of opus
  --prompt "..."  Provide task inline (otherwise opens multiline editor)
  --cwd DIR       Working directory for relative paths (default: .)
  --max-loops N   Maximum agent loop iterations (default: 200)
  --oraclepro     Use openai/gpt-5.4-pro for oracle (default: openai/gpt-5.4)
  --resume ID     Resume a previous thread by ID (from ~/.dtt/threads/)
  --verbose       Verbose error traces
  --debug         Debug-level logging of API payloads
  --keep-temp     Keep the temp runtime directory on exit

Environment:
  OPENROUTER_API_KEY   Required. Your OpenRouter API key.
HELP
      exit 0
      ;;
    *)
      PASS_ARGS+=("$arg")
      ;;
  esac
done

mkdir -p "$BASE"

for required in python3 git; do
  if ! command -v "$required" >/dev/null 2>&1; then
    echo "Error: required command not found: $required" >&2
    exit 1
  fi
done

if [ -z "${OPENROUTER_API_KEY:-}" ]; then
    echo "Error: OPENROUTER_API_KEY is not set." >&2
    exit 1
fi

cleanup() {
    local status=$?
    if [ "$KEEP_TEMP" = true ]; then
        echo "Kept temp dir: $BASE" >&2
    fi
    exit "$status"
}
trap cleanup EXIT INT TERM

# ── Main Python environment ──────────────────────────────────────
if [ -d "$VENV" ] && [ ! -f "$VENV/bin/activate" ]; then rm -rf "$VENV"; fi
if [ ! -d "$VENV" ]; then
    echo "▸ Creating Python environment..."
    python3 -m venv "$VENV"
fi
source "$VENV/bin/activate"

if [ ! -f "$BASE/.deps_v4" ]; then
    echo "▸ Installing dependencies (first run)..."
    pip install -q -U pip setuptools wheel 2>/dev/null
    pip install -q requests httpx "prompt_toolkit>=3" "camoufox[geoip]" playwright \
        html-to-markdown lxml beautifulsoup4 pyyaml Pillow \
        markitdown pypdf python-docx openpyxl tabulate 2>/dev/null
    touch "$BASE/.deps_v4"
fi

# ── SearXNG in its own venv ──────────────────────────────────────
if [ ! -f "$BASE/.searxng_v3" ]; then
    echo "▸ Installing SearXNG (first run — takes 1-2 min)..."
    [ ! -d "$BASE/searxng" ] && git clone --depth 1 -q https://github.com/searxng/searxng.git "$BASE/searxng"
    [ ! -f "$BASE/searxng_venv/bin/activate" ] && python3 -m venv "$BASE/searxng_venv"
    "$BASE/searxng_venv/bin/pip" install -q -U pip setuptools wheel pyyaml msgspec typing_extensions 2>/dev/null
    "$BASE/searxng_venv/bin/pip" install -q pdm 2>/dev/null || true
    "$BASE/searxng_venv/bin/pip" install -q --use-pep517 --no-build-isolation -e "$BASE/searxng" 2>/dev/null
    touch "$BASE/.searxng_v3"
fi

# ── Camoufox browser binary ─────────────────────────────────────
if [ ! -f "$BASE/.camoufox_v3" ]; then
    echo "▸ Fetching Camoufox browser (first run)..."
    python -m camoufox fetch 2>/dev/null
    touch "$BASE/.camoufox_v3"
fi

# ── Readability.js ───────────────────────────────────────────────
if [ ! -f "$BASE/Readability.js" ] || [ ! -s "$BASE/Readability.js" ]; then
    echo "▸ Downloading Readability.js..."
    python3 -c "
import urllib.request
from pathlib import Path
urls = [
    'https://cdn.jsdelivr.net/npm/@mozilla/readability@0.6.2/Readability.js',
    'https://unpkg.com/@mozilla/readability/Readability.js',
    'https://raw.githubusercontent.com/mozilla/readability/main/Readability.js',
]
for url in urls:
    try:
        with urllib.request.urlopen(url, timeout=30) as r:
            data = r.read()
            if len(data) > 100:
                Path('$BASE/Readability.js').write_bytes(data)
                break
    except Exception:
        continue
" 2>/dev/null || true
fi

# ── Write and exec agent ────────────────────────────────────────
cat > "$BASE/agent.py" << 'PYTHON_AGENT'
#!/usr/bin/env python3
"""dothething — autonomous AI agent | https://dotheth.ing"""

import os, sys, json, time, asyncio, signal, subprocess, socket, re, atexit
import glob as glob_mod, threading, argparse, shlex, shutil, textwrap, traceback
import fnmatch, difflib, hashlib, base64, mimetypes, uuid
from pathlib import Path
from datetime import datetime, timezone
from collections import defaultdict
from typing import Any, Dict, List, Optional, Tuple

import requests
import httpx
import yaml

try:
    from PIL import Image
except Exception:
    Image = None

# ═══════════════════════════════════════════════════════════════════
# Constants
# ═══════════════════════════════════════════════════════════════════
BASE            = Path("/tmp/dothething")
DTT_DIR         = Path.home() / ".dtt" / "threads"
OPENROUTER_URL  = "https://openrouter.ai/api/v1/chat/completions"
OPENROUTER_STATS= "https://openrouter.ai/api/v1/generation"
OPUS            = "anthropic/claude-opus-4.6"
OPUS_FAST       = "anthropic/claude-opus-4.6-fast"
SONNET          = "anthropic/claude-sonnet-4.6"
ORACLE_DEFAULT  = "openai/gpt-5.4"
ORACLE_PRO      = "openai/gpt-5.4-pro"
MAX_LOOPS       = 200
DEFAULT_CMD_TIMEOUT = 300
IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp"}
MAX_INLINE_BYTES = 5 * 1024 * 1024

def _make_headers(api_key):
    return {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
        "HTTP-Referer": "https://dotheth.ing",
        "X-Title": "dothething",
    }

# ═══════════════════════════════════════════════════════════════════
# Spinner
# ═══════════════════════════════════════════════════════════════════
class Spinner:
    FRAMES = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
    def __init__(self, enabled=True):
        self.enabled = enabled and sys.stderr.isatty()
        self._thread = None
        self._stop = threading.Event()
        self._msg = ""
        self._lock = threading.Lock()

    def start(self, msg="Thinking..."):
        if not self.enabled:
            return
        self.stop()
        with self._lock:
            self._msg = msg
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def _run(self):
        i = 0
        while not self._stop.is_set():
            with self._lock:
                msg = self._msg
            frame = self.FRAMES[i % len(self.FRAMES)]
            sys.stderr.write(f"\r\033[K{frame} {msg}")
            sys.stderr.flush()
            self._stop.wait(0.1)
            i += 1
        sys.stderr.write("\r\033[K")
        sys.stderr.flush()

    def update(self, msg):
        with self._lock:
            self._msg = msg

    def stop(self):
        if self._thread and self._thread.is_alive():
            self._stop.set()
            self._thread.join(timeout=2)
        self._thread = None

# ═══════════════════════════════════════════════════════════════════
# SearXNG — lifecycle management (separate venv)
# ═══════════════════════════════════════════════════════════════════
class SearXNG:
    def __init__(self):
        self.port = None
        self.process = None
        self.settings_path = None
        self._log_fh = None

    def _find_port(self):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.bind(("127.0.0.1", 0))
            return s.getsockname()[1]

    def start(self, spinner=None):
        self.port = self._find_port()
        if spinner:
            spinner.update(f"Starting SearXNG on :{self.port}...")

        src = BASE / "searxng"
        sample = src / "searx" / "settings.yml.sample"
        if not sample.exists():
            sample = src / "searx" / "settings.yml"
        if not sample.exists():
            return False

        with open(sample) as f:
            cfg = yaml.safe_load(f) or {}
        cfg.setdefault("server", {})
        cfg["server"]["secret_key"] = os.urandom(32).hex()
        cfg["server"]["bind_address"] = "127.0.0.1"
        cfg["server"]["port"] = self.port
        cfg["server"]["limiter"] = False
        cfg.setdefault("search", {})
        cfg["search"]["formats"] = ["html", "json"]

        self.settings_path = BASE / f"searxng_settings_{self.port}.yml"
        with open(self.settings_path, "w") as f:
            yaml.dump(cfg, f, default_flow_style=False, sort_keys=False)

        python = str(BASE / "searxng_venv" / "bin" / "python")
        env = os.environ.copy()
        env["SEARXNG_SETTINGS_PATH"] = str(self.settings_path)

        self._log_fh = open(BASE / "searxng_run.log", "w")
        self.process = subprocess.Popen(
            [python, "-m", "searx.webapp"],
            cwd=str(src),
            env=env,
            stdout=self._log_fh,
            stderr=subprocess.STDOUT,
        )
        atexit.register(self.stop)

        # Health check via actual search query (from GPT1)
        import httpx as hx
        client = hx.Client(timeout=10)
        for _ in range(90):
            time.sleep(1)
            if self.process.poll() is not None:
                return False
            try:
                resp = client.get(
                    f"http://127.0.0.1:{self.port}/search",
                    params={"q": "ping", "format": "json"},
                )
                if resp.status_code == 200:
                    client.close()
                    return True
            except Exception:
                pass
        client.close()
        return False

    def stop(self):
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.process = None
        if self._log_fh:
            self._log_fh.close()
            self._log_fh = None
        if self.settings_path and self.settings_path.exists():
            try:
                self.settings_path.unlink()
            except OSError:
                pass

    @property
    def url(self):
        return f"http://127.0.0.1:{self.port}" if self.port else None

# ═══════════════════════════════════════════════════════════════════
# Browser — Camoufox + Readability.js
# ═══════════════════════════════════════════════════════════════════
class Browser:
    def __init__(self):
        self._browser = None
        self._cm = None
        self._readability_js = None
        self._lock = asyncio.Lock()
        self._load_readability()

    def _load_readability(self):
        cache = BASE / "Readability.js"
        if cache.exists() and cache.stat().st_size > 100:
            self._readability_js = cache.read_text()
            return
        # Fallback CDN download
        for url in [
            "https://cdn.jsdelivr.net/npm/@mozilla/readability@0.6.2/Readability.js",
            "https://unpkg.com/@mozilla/readability/Readability.js",
        ]:
            try:
                r = requests.get(url, timeout=15)
                if r.ok and len(r.text) > 100:
                    self._readability_js = r.text
                    cache.write_text(r.text)
                    return
            except Exception:
                pass

    async def _ensure(self):
        async with self._lock:
            if self._browser is None:
                from camoufox.async_api import AsyncCamoufox
                self._cm = AsyncCamoufox(headless=True, humanize=True)
                self._browser = await self._cm.__aenter__()
        return self._browser

    async def fetch(self, url, mode="markdown", screenshot_region="above", timeout_ms=45000):
        try:
            browser = await self._ensure()
            page = await browser.new_page()
        except Exception as e:
            async with self._lock:
                self._browser = None
                self._cm = None
            return f"Error launching browser: {e}"
        try:
            await page.goto(url, wait_until="networkidle", timeout=timeout_ms)
            await page.wait_for_timeout(1500)

            if mode == "screenshot":
                if screenshot_region == "full":
                    data = await page.screenshot(full_page=True)
                elif screenshot_region == "below":
                    vp = page.viewport_size or {"width": 1280, "height": 720}
                    await page.evaluate("(h) => window.scrollTo(0, h)", vp.get("height", 720))
                    await page.wait_for_timeout(500)
                    data = await page.screenshot(full_page=False)
                else:  # above
                    await page.evaluate("() => window.scrollTo(0, 0)")
                    await page.wait_for_timeout(200)
                    data = await page.screenshot(full_page=False)
                ts = int(time.time() * 1000)
                path = Path(f"screenshot_{ts}.png").absolute()
                path.write_bytes(data)
                return json.dumps({
                    "type": "screenshot",
                    "url": page.url,
                    "path": str(path),
                    "region": screenshot_region,
                    "size_bytes": len(data),
                }, ensure_ascii=False, indent=2)
            elif mode == "html":
                return await page.content()
            else:
                return await self._to_markdown(page)
        except Exception as e:
            return f"Error fetching {url}: {e}"
        finally:
            try:
                await page.close()
            except Exception:
                pass

    async def _to_markdown(self, page):
        current_url = page.url
        title = await page.title()

        # Try Readability.js injection first (from all responses)
        if self._readability_js:
            try:
                await page.add_script_tag(content=self._readability_js)
                article = await page.evaluate(
                    """(() => {
                        try {
                            const clone = document.cloneNode(true);
                            const a = new Readability(clone).parse();
                            if (!a) return null;
                            return {
                                title: a.title || '',
                                byline: a.byline || '',
                                excerpt: a.excerpt || '',
                                content: a.content || '',
                                textContent: a.textContent || ''
                            };
                        } catch(e) { return null; }
                    })()"""
                )
                if article and article.get("content"):
                    from html_to_markdown import convert as to_md
                    md = to_md(article["content"])
                    header_bits = []
                    if article.get("title"):
                        header_bits.append(f"# {article['title']}")
                    if article.get("byline"):
                        header_bits.append(f"Byline: {article['byline']}")
                    if article.get("excerpt"):
                        header_bits.append(f"Excerpt: {article['excerpt']}")
                    header_bits.append(f"URL: {current_url}")
                    header = "\n\n".join(header_bits)
                    md = re.sub(r"\n{3,}", "\n\n", md).strip()
                    return f"{header}\n\n{md}"
            except Exception:
                pass

        # Fallback: strip and convert
        html = await page.content()
        from bs4 import BeautifulSoup
        from html_to_markdown import convert as to_md
        soup = BeautifulSoup(html, "lxml")
        for tag in soup(
            ["script","style","header","footer","nav","aside","iframe","noscript","svg"]
        ):
            tag.decompose()
        body = soup.body.decode_contents() if soup.body else str(soup)
        md = to_md(body)
        md = re.sub(r"\n{3,}", "\n\n", md).strip()
        return f"# {title}\n\nURL: {current_url}\n\n{md}"

    async def close(self):
        async with self._lock:
            if self._cm:
                try:
                    await self._cm.__aexit__(None, None, None)
                except Exception:
                    pass
                self._browser = None
                self._cm = None

# ═══════════════════════════════════════════════════════════════════
# Cost Tracker — background queue that fetches OpenRouter stats
# ═══════════════════════════════════════════════════════════════════
class CostTracker:
    def __init__(self, api_key):
        self.api_key = api_key
        self._queue = asyncio.Queue()
        self.entries = []
        self._task = None
        self._stopping = False
        self._http = None
        self._accounted = set()

    def start(self, http_client):
        self._http = http_client
        self._task = asyncio.create_task(self._worker())

    async def track(self, response_id, label="opus"):
        if response_id and response_id not in self._accounted:
            await self._queue.put((response_id, label, time.time(), 0))

    async def _worker(self):
        while True:
            try:
                item = await asyncio.wait_for(self._queue.get(), timeout=1.0)
            except asyncio.TimeoutError:
                if self._stopping and self._queue.empty():
                    break
                continue
            except asyncio.CancelledError:
                break

            rid, label, queued_at, attempts = item
            await asyncio.sleep(1.5)

            for attempt_n in range(8):
                try:
                    resp = await self._http.get(
                        f"{OPENROUTER_STATS}?id={rid}",
                        headers={"Authorization": f"Bearer {self.api_key}"},
                        timeout=15,
                    )
                    if resp.status_code == 200:
                        d = resp.json().get("data", {})
                        if rid not in self._accounted:
                            self._accounted.add(rid)
                            self.entries.append({
                                "label": label,
                                "model": d.get("model", label),
                                "cost": d.get("total_cost", 0) or 0,
                                "tokens_in": d.get("native_tokens_prompt", 0) or 0,
                                "tokens_out": d.get("native_tokens_completion", 0) or 0,
                                "tokens_reasoning": d.get("native_tokens_reasoning", 0) or 0,
                                "tokens_cached": d.get("native_tokens_cached", 0) or 0,
                            })
                        break
                    elif resp.status_code == 404 and attempt_n < 7:
                        await asyncio.sleep(min(1.5 + attempt_n * 0.75, 8))
                        continue
                    else:
                        break
                except Exception:
                    if attempt_n < 7:
                        await asyncio.sleep(2)
                    continue

    async def drain(self, timeout=45):
        self._stopping = True
        if self._task:
            try:
                await asyncio.wait_for(self._task, timeout=timeout)
            except (asyncio.TimeoutError, asyncio.CancelledError):
                self._task.cancel()
                try:
                    await self._task
                except asyncio.CancelledError:
                    pass

    @property
    def total_cost(self):
        return sum(e["cost"] for e in self.entries)

    def report(self):
        by_model = {}
        for e in self.entries:
            m = e.get("model", e["label"])
            if m not in by_model:
                by_model[m] = {"cost": 0, "in": 0, "out": 0, "reasoning": 0, "cached": 0, "calls": 0}
            by_model[m]["cost"] += e["cost"]
            by_model[m]["in"]  += e["tokens_in"]
            by_model[m]["out"] += e["tokens_out"]
            by_model[m]["reasoning"] += e.get("tokens_reasoning", 0)
            by_model[m]["cached"] += e.get("tokens_cached", 0)
            by_model[m]["calls"] += 1
        return by_model

# ═══════════════════════════════════════════════════════════════════
# Thread Logger — persist conversations to ~/.dtt/threads/
# ═══════════════════════════════════════════════════════════════════
class ThreadLogger:
    def __init__(self, thread_id=None):
        DTT_DIR.mkdir(parents=True, exist_ok=True)
        if thread_id:
            self.thread_id = thread_id
            self.thread_dir = DTT_DIR / thread_id
        else:
            ts = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
            uid = uuid.uuid4().hex[:8]
            self.thread_id = f"{ts}-{uid}"
            self.thread_dir = DTT_DIR / self.thread_id
        self.thread_dir.mkdir(parents=True, exist_ok=True)

    def save_messages(self, messages):
        """Save the full message history."""
        path = self.thread_dir / "messages.json"
        # Serialize, handling non-serializable content gracefully
        serializable = []
        for msg in messages:
            m = dict(msg)
            # Truncate very large tool results to avoid multi-GB thread files
            if m.get("role") == "tool" and isinstance(m.get("content"), str) and len(m["content"]) > 200_000:
                m["content"] = m["content"][:200_000] + "\n[…truncated in thread log]"
            serializable.append(m)
        path.write_text(json.dumps(serializable, ensure_ascii=False, indent=2), encoding="utf-8")

    def save_meta(self, meta):
        """Save metadata (model, cwd, prompt, etc.)."""
        path = self.thread_dir / "meta.json"
        path.write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")

    def load_messages(self):
        path = self.thread_dir / "messages.json"
        if not path.exists():
            raise FileNotFoundError(f"No thread found: {self.thread_id}")
        return json.loads(path.read_text(encoding="utf-8"))

    def load_meta(self):
        path = self.thread_dir / "meta.json"
        if path.exists():
            return json.loads(path.read_text(encoding="utf-8"))
        return {}

# ═══════════════════════════════════════════════════════════════════
# Plan Manager
# ═══════════════════════════════════════════════════════════════════
class Plan:
    def __init__(self):
        self.items = []
        self._lock = threading.Lock()

    def create(self, items):
        with self._lock:
            self.items = [{"id": i + 1, "text": t, "done": False} for i, t in enumerate(items)]
            return self._fmt()

    def remaining(self):
        with self._lock:
            rem = [i for i in self.items if not i["done"]]
            if not rem:
                return "All items completed!" if self.items else "No plan created yet."
            return self._fmt(rem)

    def complete(self, item_id):
        with self._lock:
            for i in self.items:
                if i["id"] == item_id:
                    i["done"] = True
                    return f"✓ Completed #{item_id}: {i['text']}\n\n{self._remaining_unlocked()}"
            return f"Error: Item #{item_id} not found. Use plan_remaining to see IDs."

    def _remaining_unlocked(self):
        rem = [i for i in self.items if not i["done"]]
        if not rem:
            return "All items completed!"
        return self._fmt(rem)

    def _fmt(self, items=None):
        items = items or self.items
        done = sum(1 for i in self.items if i["done"])
        lines = [f"Plan ({done}/{len(self.items)} complete):"]
        for i in items:
            s = "✓" if i["done"] else "○"
            lines.append(f"  {s} {i['id']}. {i['text']}")
        return "\n".join(lines)

    def add_items(self, items):
        with self._lock:
            next_id = max((i["id"] for i in self.items), default=0) + 1
            for text in items:
                self.items.append({"id": next_id, "text": text, "done": False})
                next_id += 1
            return self._fmt()

    def remove_items(self, ids):
        with self._lock:
            id_set = set(ids)
            self.items = [i for i in self.items if i["id"] not in id_set]
            return self._fmt()

    def snapshot(self):
        with self._lock:
            return {"items": [dict(i) for i in self.items]}


# ═══════════════════════════════════════════════════════════════════
# Notes — persistent working memory across turns
# ═══════════════════════════════════════════════════════════════════
class Notes:
    def __init__(self):
        self._entries = []

    def add(self, content):
        ts = datetime.now().strftime("%H:%M:%S")
        self._entries.append(f"[{ts}] {content}")
        return f"Note #{len(self._entries)} recorded ({len(content)} chars). " \
               f"Total notes: {len(self._entries)}. Use notes_read to recall all."

    def read(self):
        if not self._entries:
            return "No notes yet."
        return "\n\n".join(f"#{i+1} {e}" for i, e in enumerate(self._entries))

    def clear(self):
        n = len(self._entries)
        self._entries.clear()
        return f"Cleared {n} notes."

# ═══════════════════════════════════════════════════════════════════
# Utility functions
# ═══════════════════════════════════════════════════════════════════
def resolve_path(cwd, path_str):
    p = Path(path_str).expanduser()
    if not p.is_absolute():
        p = Path(cwd) / p
    return p.resolve(strict=False)

def is_binary_data(data):
    if not data:
        return False
    if b"\x00" in data:
        return True
    textchars = bytearray({7, 8, 9, 10, 12, 13, 27} | set(range(0x20, 0x100)))
    return bool(data.translate(None, textchars))

def file_sha256(path):
    if not path.exists():
        return None
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()

def parse_regex_flags(flag_text):
    flags = 0
    for f in [x.strip().upper() for x in flag_text.replace(",", " ").split() if x.strip()]:
        if f in ("I", "IGNORECASE"):
            flags |= re.IGNORECASE
        elif f in ("M", "MULTILINE"):
            flags |= re.MULTILINE
        elif f in ("S", "DOTALL"):
            flags |= re.DOTALL
        elif f in ("X", "VERBOSE"):
            flags |= re.VERBOSE
        else:
            raise RuntimeError(f"Unsupported regex flag: {f}")
    return flags

# SEARCH/REPLACE patch format from GPT2
PATCH_BLOCK_RE = re.compile(
    r"<<<<<<< SEARCH\n(.*?)\n=======\n(.*?)\n>>>>>>> REPLACE",
    re.DOTALL,
)

def apply_search_replace_patch(content, patch_text):
    matches = list(PATCH_BLOCK_RE.finditer(patch_text))
    if not matches:
        raise RuntimeError("No valid SEARCH/REPLACE blocks found in patch")
    updated = content
    for match in matches:
        search = match.group(1)
        replace = match.group(2)
        occurrences = updated.count(search)
        if occurrences == 0:
            # Fallback: try whitespace-normalized matching
            search_lines = search.split('\n')
            norm_search_lines = [re.sub(r'[ \t]+', ' ', l).strip() for l in search_lines]
            content_lines = updated.split('\n')

            match_start = None
            for i in range(len(content_lines) - len(search_lines) + 1):
                window = [re.sub(r'[ \t]+', ' ', content_lines[i + j]).strip()
                          for j in range(len(search_lines))]
                if window == norm_search_lines:
                    if match_start is not None:
                        raise RuntimeError(
                            "SEARCH block matched multiple locations (whitespace-normalized); "
                            "make the search text more unique"
                        )
                    match_start = i

            if match_start is not None:
                before = content_lines[:match_start]
                after = content_lines[match_start + len(search_lines):]
                updated = '\n'.join(before + replace.split('\n') + after)
                if content.endswith('\n') and not updated.endswith('\n'):
                    updated += '\n'
            else:
                # Provide diagnostic: find closest matching lines
                from difflib import get_close_matches
                first_search_line = search_lines[0].strip() if search_lines else ""
                close = get_close_matches(first_search_line,
                                          [l.strip() for l in content_lines],
                                          n=3, cutoff=0.5)
                hint = ""
                if close:
                    hint = f"\n\nNearest lines in file:\n" + "\n".join(f"  {l}" for l in close)
                    hint += f"\n\nFile has {len(content_lines)} lines. Re-read the target section " \
                            f"with read_file (result_mode='raw') and retry with exact text."
                raise RuntimeError(
                    f"SEARCH block did not match the file content "
                    f"(tried exact and whitespace-normalized). "
                    f"First 80 chars of search: {search[:80]!r}{hint}"
                )
        elif occurrences > 1:
            raise RuntimeError("SEARCH block matched multiple locations; make it unique or use regex mode")
        else:
            updated = updated.replace(search, replace, 1)
    return updated

# Unified diff patch application from GPT1
def _strip_patch_path(value):
    value = value.strip()
    if value.startswith("a/") or value.startswith("b/"):
        return value[2:]
    return value

def apply_unified_patch(cwd, patch_text):
    """Apply a unified diff patch. Returns list of changed file paths."""
    lines = patch_text.splitlines(keepends=True)
    changed_files = []
    idx = 0
    while idx < len(lines):
        line = lines[idx]
        if not line.startswith("--- "):
            idx += 1
            continue
        old_path = _strip_patch_path(line[4:].strip().split("\t")[0])
        idx += 1
        if idx >= len(lines) or not lines[idx].startswith("+++ "):
            raise RuntimeError("Malformed patch: expected +++ after ---")
        new_path = _strip_patch_path(lines[idx][4:].strip().split("\t")[0])
        idx += 1

        if old_path == "/dev/null":
            source_lines = []
        else:
            source_file = resolve_path(cwd, old_path)
            if not source_file.exists():
                raise RuntimeError(f"Patch source file does not exist: {source_file}")
            source_lines = source_file.read_text(encoding="utf-8").splitlines(keepends=True)

        hunks = []
        while idx < len(lines) and lines[idx].startswith("@@ "):
            header = lines[idx]
            match = re.match(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", header)
            if not match:
                raise RuntimeError(f"Malformed hunk header: {header}")
            old_start = int(match.group(1))
            idx += 1
            hunk_lines = []
            while idx < len(lines):
                current = lines[idx]
                if current.startswith("@@ ") or current.startswith("--- "):
                    break
                if current.startswith((" ", "+", "-", "\\")):
                    hunk_lines.append(current)
                    idx += 1
                    continue
                break
            hunks.append((old_start, hunk_lines))

        output_lines = []
        src_index = 0
        for old_start, hunk_lines in hunks:
            target_index = max(old_start - 1, 0)
            output_lines.extend(source_lines[src_index:target_index])
            src_index = target_index
            for hline in hunk_lines:
                marker = hline[:1]
                if marker == " ":
                    if src_index < len(source_lines):
                        output_lines.append(source_lines[src_index])
                    src_index += 1
                elif marker == "-":
                    src_index += 1
                elif marker == "+":
                    output_lines.append(hline[1:])
                elif marker == "\\":
                    continue
        output_lines.extend(source_lines[src_index:])

        if new_path == "/dev/null":
            target_file = resolve_path(cwd, old_path)
            if target_file.exists():
                target_file.unlink()
            changed_files.append(str(target_file))
            continue
        target_file = resolve_path(cwd, new_path)
        target_file.parent.mkdir(parents=True, exist_ok=True)
        target_file.write_text("".join(output_lines), encoding="utf-8")
        changed_files.append(str(target_file))

    if not changed_files:
        raise RuntimeError("Patch contained no file diffs")
    return changed_files

# JSON fallback tool call parsing from GPT1
def parse_fallback_tool_calls(text):
    candidate = text.strip()
    if not candidate:
        return None
    if candidate.startswith("```"):
        candidate = re.sub(r"^```(?:json)?\s*", "", candidate)
        candidate = re.sub(r"\s*```$", "", candidate)
        candidate = candidate.strip()
    try:
        data = json.loads(candidate)
    except Exception:
        return None
    if isinstance(data, dict) and "tool_calls" in data and isinstance(data["tool_calls"], list):
        tool_calls = []
        for idx, entry in enumerate(data["tool_calls"], start=1):
            if not isinstance(entry, dict):
                continue
            tool_name = entry.get("tool")
            arguments = entry.get("arguments") or {}
            if not isinstance(tool_name, str) or not isinstance(arguments, dict):
                continue
            tool_calls.append({
                "id": f"fallback-{idx}-{int(time.time() * 1000)}",
                "type": "function",
                "function": {
                    "name": tool_name,
                    "arguments": json.dumps(arguments, ensure_ascii=False),
                },
            })
        return tool_calls or None
    if isinstance(data, dict) and isinstance(data.get("tool"), str) and isinstance(data.get("arguments"), dict):
        return [{
            "id": f"fallback-1-{int(time.time() * 1000)}",
            "type": "function",
            "function": {
                "name": data["tool"],
                "arguments": json.dumps(data["arguments"], ensure_ascii=False),
            },
        }]
    return None

# ═══════════════════════════════════════════════════════════════════
# Smart Summarizer — pipes big outputs through Sonnet
# ═══════════════════════════════════════════════════════════════════
async def smart_summarize(raw, goal, headers, cost_tracker, http, tool_name="unknown"):
    if not raw or not raw.strip():
        return raw or "(empty output)"
    if len(raw) > 280_000:
        raw = raw[:280_000] + f"\n\n[…truncated, {len(raw)-280_000:,} chars omitted]"
    for attempt in range(2):
        try:
            resp = await http.post(
                OPENROUTER_URL,
                headers=headers,
                json={
                    "model": SONNET,
                    "messages": [
                        {
                            "role": "system",
                            "content": (
                                "You are a precision summarizer for a general-purpose autonomous AI agent. "
                                f"This output comes from the '{tool_name}' tool. "
                                f"The agent's goal for this output is: \"{goal}\"\n\n"
                                "Rules:\n"
                                "1. Extract ONLY information relevant to the stated goal.\n"
                                "2. Preserve: exact file paths, line numbers, error messages, exit codes, "
                                "URLs, command names, numeric values, dates, config keys, identifiers, "
                                "table data, and source attributions.\n"
                                "3. Omit: boilerplate, repeated patterns (summarize as 'N similar entries'), "
                                "verbose success messages, decorative formatting.\n"
                                "4. Use compact formatting: bullets, not prose paragraphs.\n"
                                "5. If the output contains errors/failures, lead with those.\n"
                                "6. Never invent, infer, or add information not present in the source.\n"
                                "7. If nothing in the output is relevant to the goal, say so explicitly."
                            ),
                        },
                        {"role": "user", "content": raw},
                    ],
                    "temperature": 0.0,
                    "max_tokens": 8192,
                },
                timeout=120,
            )
            result = resp.json()
            rid = result.get("id")
            if rid:
                await cost_tracker.track(rid, "sonnet")
            if "error" in result:
                raise RuntimeError(result["error"])
            content = result["choices"][0]["message"]["content"]
            if isinstance(content, list):
                content = "\n".join(
                    p.get("text", "") if isinstance(p, dict) and p.get("type") == "text"
                    else str(p) if isinstance(p, str) else ""
                    for p in content
                ).strip()
            return f"[Summarized — goal: {goal}]\n{content}"
        except Exception as e:
            if attempt == 0:
                await asyncio.sleep(1)
                continue
            trunc = raw[:8000] + "\n[…summarization failed, showing raw head]" if len(raw) > 8000 else raw
            return trunc

# ═══════════════════════════════════════════════════════════════════
# Tool Definitions — OpenAI function-calling schema
# ═══════════════════════════════════════════════════════════════════
RESULT_MODE_PROP = {
    "type": "string",
    "description": "Mandatory. 'raw' for exact unprocessed output, or a goal string for Sonnet-summarized output.",
}

TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "read_file",
            "description": "Read a file. result_mode='raw' for exact content. Otherwise describe what you need for summarised output. Supports start_line/end_line for partial reads.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "File path (relative or absolute)"},
                    "start_line": {"type": "integer", "minimum": 1, "description": "First line to read (1-based)"},
                    "end_line": {"type": "integer", "minimum": 1, "description": "Last line to read (inclusive)"},
                    "result_mode": RESULT_MODE_PROP,
                },
                "required": ["path", "result_mode"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "write_file",
            "description": "Write content to a file. Creates parent directories automatically. mode='overwrite' (default) or 'append'.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string"},
                    "content": {"type": "string", "description": "Complete file content"},
                    "mode": {"type": "string", "enum": ["overwrite", "append"], "description": "Write mode (default: overwrite)"},
                    "result_mode": RESULT_MODE_PROP,
                },
                "required": ["path", "content", "result_mode"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "glob",
            "description": "List files matching a glob pattern (supports ** for recursive).",
            "parameters": {
                "type": "object",
                "properties": {
                    "pattern": {"type": "string", "description": "Glob pattern, e.g. '**/*.py'"},
                    "path": {"type": "string", "description": "Base directory (default: .)"},
                    "include_hidden": {"type": "boolean", "description": "Include hidden files/dirs (default: false)"},
                    "result_mode": RESULT_MODE_PROP,
                },
                "required": ["pattern", "result_mode"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "edit_file",
            "description": (
                "Edit a file. Supports three modes:\n"
                "1. mode='search_replace': Provide patch with <<<<<<< SEARCH / ======= / >>>>>>> REPLACE blocks.\n"
                "2. mode='regex': Provide pattern + replacement (Python regex).\n"
                "3. mode='unified_diff': Provide a unified diff patch.\n"
                "Always read the target section first so your search text is exact."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string"},
                    "mode": {"type": "string", "enum": ["search_replace", "regex", "unified_diff"]},
                    "patch": {"type": "string", "description": "SEARCH/REPLACE blocks or unified diff text"},
                    "pattern": {"type": "string", "description": "Regex pattern (for regex mode)"},
                    "replacement": {"type": "string", "description": "Replacement text (for regex mode)"},
                    "flags": {"type": "string", "description": "Regex flags: i,m,s,x or IGNORECASE,MULTILINE,DOTALL,VERBOSE"},
                    "count": {"type": "integer", "minimum": 0, "description": "Max replacements for regex (0=all)"},
                    "result_mode": RESULT_MODE_PROP,
                },
                "required": ["path", "mode", "result_mode"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "search_file",
            "description": "Search for files by name (glob/regex) or content (ripgrep/grep). At least one of name_glob, name_regex, or content_query required.",
            "parameters": {
                "type": "object",
                "properties": {
                    "name_glob": {"type": "string", "description": "Filename glob pattern"},
                    "name_regex": {"type": "string", "description": "Filename regex"},
                    "content_query": {"type": "string", "description": "Text/regex to search inside files"},
                    "content_is_regex": {"type": "boolean", "description": "Treat content_query as regex (default: false)"},
                    "path": {"type": "string", "description": "Directory to search (default: .)"},
                    "max_results": {"type": "integer", "description": "Max results (default: 50)"},
                    "result_mode": RESULT_MODE_PROP,
                },
                "required": ["result_mode"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "run_command",
            "description": "Execute a shell command via /bin/bash. Captures stdout+stderr. Use result_mode to summarize large outputs.",
            "parameters": {
                "type": "object",
                "properties": {
                    "command": {"type": "string", "description": "Shell command"},
                    "cwd": {"type": "string", "description": "Working directory for the command"},
                    "timeout": {"type": "integer", "description": "Timeout in seconds (default 300)"},
                    "env": {"type": "object", "additionalProperties": {"type": "string"}, "description": "Extra env vars"},
                    "result_mode": RESULT_MODE_PROP,
                },
                "required": ["command", "result_mode"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "search_web",
            "description": "Search the web via local SearXNG. Returns title, URL, and snippet for each result.",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "Search query"},
                    "num_results": {"type": "integer", "description": "Max results (default 10)"},
                    "result_mode": RESULT_MODE_PROP,
                },
                "required": ["query", "result_mode"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "fetch_page",
            "description": (
                "Fetch a web page via headless Camoufox browser. "
                "mode='markdown' (Readability.js extraction), 'screenshot' (PNG), or 'html' (rendered DOM). "
                "For screenshots, screenshot_region can be 'above' (above fold), 'below' (below fold), or 'full'."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "url": {"type": "string"},
                    "mode": {"type": "string", "enum": ["markdown", "screenshot", "html"], "description": "Fetch mode (default: markdown)"},
                    "screenshot_region": {"type": "string", "enum": ["above", "below", "full"], "description": "Screenshot region (default: above)"},
                    "timeout_ms": {"type": "integer", "description": "Page load timeout in ms (default: 45000)"},
                    "result_mode": RESULT_MODE_PROP,
                },
                "required": ["url", "result_mode"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "plan_create",
            "description": "Create a numbered step-by-step plan. Call at the START of every task.",
            "parameters": {
                "type": "object",
                "properties": {
                    "items": {"type": "array", "items": {"type": "string"}, "description": "Ordered list of plan steps"},
                    "result_mode": RESULT_MODE_PROP,
                },
                "required": ["items", "result_mode"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "plan_remaining",
            "description": "Show remaining incomplete plan items with their numeric IDs.",
            "parameters": {
                "type": "object",
                "properties": {"result_mode": RESULT_MODE_PROP},
                "required": ["result_mode"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "plan_completed",
            "description": "Mark a plan item as done by ID. Call plan_remaining first to see IDs.",
            "parameters": {
                "type": "object",
                "properties": {
                    "item_id": {"type": "integer", "description": "Plan item ID to mark done"},
                    "result_mode": RESULT_MODE_PROP,
                },
                "required": ["item_id", "result_mode"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "think",
            "description": "Free-form reasoning scratchpad. Zero cost. Use to plan, debug, or reason before acting.",
            "parameters": {
                "type": "object",
                "properties": {
                    "thought": {"type": "string", "description": "Your reasoning"},
                    "result_mode": RESULT_MODE_PROP,
                },
                "required": ["thought", "result_mode"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "oracle",
            "description": (
                "Consult GPT-5.4 (or GPT-5.4-pro with --oraclepro) for deep reasoning or a second opinion. "
                "Set include_context=true to send the full conversation history. Use sparingly."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "question": {"type": "string", "description": "Question or problem"},
                    "include_context": {"type": "boolean", "description": "Send full conversation context (default false)"},
                    "result_mode": RESULT_MODE_PROP,
                },
                "required": ["question", "result_mode"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "finalize",
            "description": "Complete the task. Provide a concise final report. Call ONLY when ALL work is done. Must be the only tool call in its response.",
            "parameters": {
                "type": "object",
                "properties": {
                    "report": {"type": "string", "description": "Final summary report for the user"},
                    "files": {"type": "array", "items": {"type": "string"}, "description": "Key files created/modified"},
                },
                "required": ["report"],
            },
        },
    },
]

# ═══════════════════════════════════════════════════════════════════
# System Prompt
# ═══════════════════════════════════════════════════════════════════
SYSTEM_PROMPT = """\
You are "dothething", an autonomous AI agent with unrestricted filesystem \
access, shell execution, and internet capabilities. You work completely \
independently until the task is done.

## Rules
1. ALWAYS use tools. Never reply with only text — use a tool or finalize.
2. result_mode is MANDATORY on every tool except finalize:
   - "raw" → exact unprocessed output. Use SPARINGLY (precise syntax, \
specific values only).
   - "<goal>" → output is summarized by a secondary AI focused on your \
stated goal. Use this for anything potentially large.
3. Start every task with plan_create.
4. Mark progress with plan_completed as you go.
5. Call finalize when done. NEVER stop without it. finalize must be the ONLY \
tool call in that response.
6. When you need multiple independent things, call all tools in ONE turn \
(parallel execution).
7. think is free — use it to reason before complex actions.
8. oracle calls GPT-5.4. Reserve for genuinely hard problems.

## Tool Tips
- read_file: result_mode="find the auth middleware logic" not "raw"
- run_command: result_mode="did tests pass, which failed" not "raw"
- edit_file: read the target section first so search text / old_text is exact
- edit_file mode=search_replace: use <<<<<<< SEARCH / ======= / >>>>>>> REPLACE blocks
- edit_file mode=regex: Python re.sub with pattern/replacement
- edit_file mode=unified_diff: standard unified diff format
- search_file content_query uses ripgrep (fast, respects .gitignore)
- fetch_page markdown mode uses Readability.js for clean extraction
- fetch_page screenshot mode saves PNG, use result_mode to describe image if not raw

## Native tool-call fallback
If native OpenRouter tool-calls fail, you may return exactly one JSON object:
{{"tool_calls": [{{"tool": "read_file", "arguments": {{"path": "README.md", "result_mode": "raw"}}}}]}}
or single: {{"tool": "finalize", "arguments": {{"report": "Done."}}}}

## Context
- Working directory: {cwd}
- Date/time: {datetime}
- Platform: {platform}
- Thread: {thread_id}
"""

# ═══════════════════════════════════════════════════════════════════
# Agent
# ═══════════════════════════════════════════════════════════════════
class Agent:
    DISPATCH = {
        "read_file":       "_tool_read_file",
        "write_file":      "_tool_write_file",
        "glob":            "_tool_glob",
        "edit_file":       "_tool_edit_file",
        "search_file":     "_tool_search_file",
        "run_command":      "_tool_run_command",
        "search_web":      "_tool_search_web",
        "fetch_page":      "_tool_fetch_page",
        "plan_create":     "_tool_plan_create",
        "plan_remaining":  "_tool_plan_remaining",
        "plan_completed":  "_tool_plan_completed",
        "think":           "_tool_think",
        "oracle":          "_tool_oracle",
        "finalize":        "_tool_finalize",
    }

    def __init__(self, model, oracle_model, api_key, cwd, debug=False, verbose=False):
        self.model = model
        self.oracle_model = oracle_model
        self.api_key = api_key
        self.cwd = cwd
        self.debug = debug
        self.verbose = verbose
        self.headers = _make_headers(api_key)
        self.messages = []
        self.searxng = SearXNG()
        self.browser = Browser()
        self.cost_tracker = CostTracker(api_key)
        self.plan = Plan()
        self.spinner = Spinner(enabled=not verbose)
        self.thread_logger = None
        self.http = None
        self._finalized = False
        self._final_report = None
        self._final_files = []

    # ── Setup ────────────────────────────────────────────────────
    async def setup(self):
        self.http = httpx.AsyncClient(timeout=1800)
        self.cost_tracker.start(self.http)

        self.spinner.start("Starting SearXNG...")
        ok = self.searxng.start(self.spinner)
        self.spinner.stop()
        if ok:
            print(f"  ✓ SearXNG on port {self.searxng.port}", file=sys.stderr)
        else:
            print("  ⚠ SearXNG unavailable — web search disabled", file=sys.stderr)

    # ── Tool implementations ─────────────────────────────────────
    async def _tool_read_file(self, path, start_line=None, end_line=None, **kw):
        p = resolve_path(self.cwd, path)
        if not p.exists():
            return f"Error: File not found: {path}"
        if p.is_dir():
            return f"Error: {path} is a directory, not a file"
        try:
            data = p.read_bytes()
            if is_binary_data(data):
                info = {
                    "path": str(p),
                    "binary": True,
                    "size": len(data),
                    "sha256": hashlib.sha256(data).hexdigest(),
                    "mime": mimetypes.guess_type(str(p))[0] or "application/octet-stream",
                }
                return json.dumps(info, indent=2)
            text = data.decode("utf-8", errors="replace")
            if start_line is not None or end_line is not None:
                lines = text.splitlines()
                s = max((int(start_line) if start_line else 1) - 1, 0)
                e = int(end_line) if end_line else len(lines)
                numbered = [f"{idx}: {line}" for idx, line in enumerate(lines[s:e], start=s + 1)]
                text = "\n".join(numbered)
            return text
        except Exception as e:
            return f"Error reading {path}: {e}"

    async def _tool_write_file(self, path, content, mode=None, **kw):
        p = resolve_path(self.cwd, path)
        mode = mode or "overwrite"
        try:
            p.parent.mkdir(parents=True, exist_ok=True)
            before_hash = file_sha256(p)
            op = "a" if mode == "append" else "w"
            with p.open(op, encoding="utf-8") as f:
                f.write(content)
            after_hash = file_sha256(p)
            return json.dumps({
                "path": str(p),
                "mode": mode,
                "bytes_written": len(content.encode("utf-8")),
                "before_sha256": before_hash,
                "after_sha256": after_hash,
            }, indent=2)
        except Exception as e:
            return f"Error writing {path}: {e}"

    async def _tool_glob(self, pattern, path=None, include_hidden=False, **kw):
        root = resolve_path(self.cwd, path or ".")
        files = []
        for p in root.glob(pattern):
            rel = os.path.relpath(str(p), str(self.cwd))
            if not include_hidden and any(part.startswith(".") for part in Path(rel).parts):
                continue
            files.append(rel)
        files = sorted(set(files))
        if not files:
            return "No files matched."
        return json.dumps({"root": str(root), "pattern": pattern, "matches": files}, indent=2)

    async def _tool_edit_file(self, path, mode, patch=None, pattern=None,
                              replacement=None, flags=None, count=None, **kw):
        p = resolve_path(self.cwd, path)
        if not p.exists():
            return f"Error: File not found: {path}"
        try:
            original = p.read_text(encoding="utf-8", errors="replace")
            updated = original

            if mode == "search_replace":
                if not patch:
                    return "Error: patch is required for search_replace mode"
                updated = apply_search_replace_patch(original, patch)
            elif mode == "regex":
                if not pattern:
                    return "Error: pattern is required for regex mode"
                re_flags = parse_regex_flags(flags or "")
                cnt = int(count) if count else 0
                updated, n = re.subn(pattern, replacement or "", original, count=cnt, flags=re_flags)
                if n == 0:
                    return f"Error: Regex pattern not found in {path}"
            elif mode == "unified_diff":
                if not patch:
                    return "Error: patch is required for unified_diff mode"
                changed = apply_unified_patch(self.cwd, patch)
                return json.dumps({"mode": "unified_diff", "changed_files": changed}, indent=2)
            else:
                return f"Error: Unknown edit mode '{mode}'. Use search_replace, regex, or unified_diff."

            if updated == original:
                return "Warning: No changes were applied."
            p.write_text(updated, encoding="utf-8")
            diff = "\n".join(difflib.unified_diff(
                original.splitlines(), updated.splitlines(),
                fromfile=str(p), tofile=str(p), lineterm="",
            ))
            return diff or "Edit applied (no visible diff)."
        except Exception as e:
            return f"Error editing {path}: {e}"

    async def _tool_search_file(self, name_glob=None, name_regex=None,
                                 content_query=None, content_is_regex=False,
                                 path=None, max_results=None, **kw):
        if not (name_glob or name_regex or content_query):
            return "Error: At least one of name_glob, name_regex, or content_query required."
        root = resolve_path(self.cwd, path or ".")
        max_results = max_results or 50
        results = {"root": str(root), "name_matches": [], "content_matches": []}

        if name_glob or name_regex:
            regex_obj = re.compile(str(name_regex)) if name_regex else None
            for p in root.rglob("*"):
                rel = os.path.relpath(str(p), str(self.cwd))
                if name_glob and not fnmatch.fnmatch(p.name, str(name_glob)):
                    continue
                if regex_obj and not regex_obj.search(p.name):
                    continue
                results["name_matches"].append(rel)
                if len(results["name_matches"]) >= max_results:
                    break

        if content_query:
            rg = shutil.which("rg")
            if rg:
                cmd_parts = [rg, "-n", "--no-heading", "--color", "never"]
                if not content_is_regex:
                    cmd_parts.append("-F")
                cmd_parts.extend([str(content_query), str(root)])
                proc = await asyncio.create_subprocess_exec(
                    *cmd_parts,
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                )
                stdout, stderr = await proc.communicate()
                if proc.returncode not in (0, 1):
                    pass  # rg error, fall through
                lines = stdout.decode("utf-8", errors="replace").splitlines()
                results["content_matches"] = lines[:max_results]
            else:
                cmd = f"grep -rn {shlex.quote(str(content_query))} {shlex.quote(str(root))} 2>/dev/null | head -{max_results}"
                proc = await asyncio.create_subprocess_shell(
                    cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
                )
                stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=60)
                results["content_matches"] = stdout.decode(errors="replace").strip().splitlines()

        return json.dumps(results, ensure_ascii=False, indent=2)

    async def _tool_run_command(self, command, cwd=None, timeout=None, env=None, **kw):
        timeout = timeout or DEFAULT_CMD_TIMEOUT
        run_cwd = resolve_path(self.cwd, cwd or ".")
        process_env = os.environ.copy()
        if env:
            for k, v in env.items():
                process_env[str(k)] = str(v)
        start = time.time()
        try:
            proc = await asyncio.create_subprocess_shell(
                command,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=str(run_cwd),
                env=process_env,
                executable="/bin/bash",
            )
            timed_out = False
            try:
                stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout)
            except asyncio.TimeoutError:
                timed_out = True
                proc.kill()
                stdout, stderr = await proc.communicate()
            duration = time.time() - start
            return json.dumps({
                "command": command,
                "cwd": str(run_cwd),
                "exit_code": proc.returncode,
                "timed_out": timed_out,
                "duration_sec": round(duration, 3),
                "stdout": stdout.decode(errors="replace"),
                "stderr": stderr.decode(errors="replace"),
            }, ensure_ascii=False, indent=2)
        except Exception as e:
            return f"Command error: {e}"

    async def _tool_search_web(self, query, num_results=None, **kw):
        num_results = num_results or 10
        if not self.searxng.url:
            return "Error: SearXNG unavailable. Web search is disabled this session."
        try:
            resp = await self.http.get(
                f"{self.searxng.url}/search",
                params={"q": query, "format": "json", "categories": "general"},
                timeout=20,
            )
            data = resp.json()
            results = data.get("results", [])[:num_results]
            out = []
            for r in results:
                out.append({
                    "title": r.get("title", ""),
                    "url": r.get("url", ""),
                    "snippet": r.get("content", "")[:500],
                    "engine": r.get("engine", ""),
                })
            return json.dumps(out, ensure_ascii=False, indent=2)
        except Exception as e:
            return f"Search error: {e}"

    async def _tool_fetch_page(self, url, mode=None, screenshot_region=None,
                                timeout_ms=None, **kw):
        mode = mode or "markdown"
        screenshot_region = screenshot_region or "above"
        timeout_ms = timeout_ms or 45000
        return await self.browser.fetch(url, mode, screenshot_region, timeout_ms)

    async def _tool_plan_create(self, items, **kw):
        return self.plan.create(items)

    async def _tool_plan_remaining(self, **kw):
        return self.plan.remaining()

    async def _tool_plan_completed(self, item_id, **kw):
        return self.plan.complete(item_id)

    async def _tool_think(self, thought, **kw):
        return "Thought recorded."

    async def _tool_oracle(self, question, include_context=False, **kw):
        msgs = []
        system = (
            "You are an external oracle assisting an autonomous coding agent. "
            "Answer rigorously. If context is provided, use it. Be concrete and actionable."
        )
        if include_context:
            # Build condensed context
            for m in self.messages:
                if m.get("role") == "tool":
                    c = m.get("content", "")
                    if len(c) > 2000:
                        c = c[:2000] + "…[truncated]"
                    msgs.append({"role": "user", "content": f"[Tool result: {c}]"})
                elif m.get("role") == "assistant":
                    c = m.get("content") or ""
                    if c:
                        msgs.append({"role": "assistant", "content": c[:4000]})
                elif m.get("role") in ("system", "user"):
                    msgs.append(m)
        msgs.append({"role": "user", "content": question})
        try:
            resp = await self.http.post(
                OPENROUTER_URL,
                headers=self.headers,
                json={
                    "model": self.oracle_model,
                    "messages": [{"role": "system", "content": system}] + msgs,
                    "temperature": 0.2,
                    "max_tokens": 16384,
                    "plugins": [{"id": "web"}],
                    "reasoning": {"effort": "xhigh"},
                },
                timeout=300,
            )
            result = resp.json()
            rid = result.get("id")
            if rid:
                await self.cost_tracker.track(rid, "oracle")
            if "error" in result:
                err = result["error"]
                return f"Oracle error: {err.get('message', err) if isinstance(err, dict) else err}"
            content = result["choices"][0]["message"]["content"]
            if isinstance(content, list):
                content = "\n".join(
                    p.get("text", "") if isinstance(p, dict) and p.get("type") == "text"
                    else str(p) if isinstance(p, str) else ""
                    for p in content
                ).strip()
            return content
        except Exception as e:
            return f"Oracle error: {e}"

    async def _tool_finalize(self, report="Task completed.", files=None, **kw):
        self._finalized = True
        self._final_report = report
        self._final_files = files or []
        return report

    # ── Main loop ────────────────────────────────────────────────
    async def run(self, prompt, max_loops=MAX_LOOPS, resume_messages=None):
        import platform as plat
        now = datetime.now().astimezone()
        thread_id = self.thread_logger.thread_id if self.thread_logger else "unknown"
        sys_prompt = SYSTEM_PROMPT.format(
            cwd=self.cwd,
            datetime=now.strftime("%Y-%m-%d %H:%M %Z"),
            platform=f"{plat.system()} {plat.machine()}",
            thread_id=thread_id,
        )

        if resume_messages:
            # Resume: replace system prompt with fresh one, keep the rest
            self.messages = [{"role": "system", "content": sys_prompt}]
            for m in resume_messages:
                if m.get("role") != "system":
                    self.messages.append(m)
            self.messages.append({
                "role": "user",
                "content": "[System] Resumed. Continue where you left off. Use plan_remaining to check progress.",
            })
        else:
            self.messages = [
                {"role": "system", "content": sys_prompt},
                {"role": "user", "content": prompt},
            ]

        # Save initial state
        if self.thread_logger:
            self.thread_logger.save_meta({
                "model": self.model,
                "oracle_model": self.oracle_model,
                "cwd": str(self.cwd),
                "prompt": prompt,
                "started_at": now.isoformat(),
                "thread_id": thread_id,
            })
            self.thread_logger.save_messages(self.messages)

        nudge_count = 0
        for loop in range(max_loops):
            self.spinner.start(f"Thinking (turn {loop + 1})…")
            result = await self._call_model()
            self.spinner.stop()

            if not result:
                print("  ⚠ Empty response — retrying…", file=sys.stderr)
                await asyncio.sleep(2)
                continue

            choice = result.get("choices", [{}])[0]
            msg = choice.get("message", {})
            text = msg.get("content")
            if isinstance(text, list):
                text = "\n".join(
                    p.get("text", "") if isinstance(p, dict) and p.get("type") == "text"
                    else str(p) if isinstance(p, str) else ""
                    for p in text
                ).strip()

            if text and text.strip():
                print(f"\n┌─ Agent {'─' * 50}", file=sys.stderr)
                for line in text.split("\n"):
                    print(f"│ {line}", file=sys.stderr)
                print(f"└{'─' * 57}", file=sys.stderr)

            tool_calls = msg.get("tool_calls")

            # Fallback: parse JSON tool calls from text (from GPT1)
            if not tool_calls and text:
                fallback = parse_fallback_tool_calls(text)
                if fallback:
                    tool_calls = fallback
                    text = None  # Don't store the JSON as text content

            if not tool_calls:
                nudge_count += 1
                self.messages.append({"role": "assistant", "content": text or ""})
                if nudge_count >= 3:
                    print("  ⚠ Model won't use tools — forcing stop.", file=sys.stderr)
                    break
                self.messages.append({
                    "role": "user",
                    "content": (
                        "[System] You MUST call tools. Continue working or call finalize when done. "
                        "Do not answer the user directly."
                    ),
                })
                if self.thread_logger:
                    self.thread_logger.save_messages(self.messages)
                continue
            nudge_count = 0

            # Validate finalize is alone (from GPT1)
            names = [tc["function"]["name"] for tc in tool_calls]
            if "finalize" in names and (len(tool_calls) != 1 or names[0] != "finalize"):
                # finalize must be alone
                assistant_msg = {"role": "assistant"}
                if text:
                    assistant_msg["content"] = text
                assistant_msg["tool_calls"] = tool_calls
                self.messages.append(assistant_msg)
                fin_idx = names.index("finalize")
                self.messages.append({
                    "role": "tool",
                    "tool_call_id": tool_calls[fin_idx]["id"],
                    "content": "Error: finalize must be the only tool call in its response. Retry with finalize alone.",
                })
                # Add empty results for non-finalize calls
                for i, tc in enumerate(tool_calls):
                    if i != fin_idx:
                        self.messages.append({
                            "role": "tool",
                            "tool_call_id": tc["id"],
                            "content": "(skipped — finalize must be alone)",
                        })
                if self.thread_logger:
                    self.thread_logger.save_messages(self.messages)
                continue

            assistant_msg = {"role": "assistant"}
            if text is not None:
                assistant_msg["content"] = text
            assistant_msg["tool_calls"] = tool_calls
            self.messages.append(assistant_msg)

            self.spinner.start("Executing tools…")
            results = await self._execute_tools(tool_calls)
            self.spinner.stop()

            for r in results:
                self.messages.append(r)

            # Save after every tool execution
            if self.thread_logger:
                self.thread_logger.save_messages(self.messages)

            if self._finalized:
                for tc, r in zip(tool_calls, results):
                    if tc["function"]["name"] == "finalize":
                        self._show_final(r["content"])
                        return
                self._show_final("(finalize called)")
                return

        print("\n  ⚠ Maximum loops reached.", file=sys.stderr)

    # ── Model call with retry ────────────────────────────────────
    async def _call_model(self, retries=3):
        for attempt in range(retries):
            try:
                payload = {
                    "model": self.model,
                    "messages": self.messages,
                    "tools": TOOLS,
                    "tool_choice": "auto",
                    "temperature": 0.2,
                    "max_tokens": 16384,
                    # Enable native web search for the main model
                    "plugins": [{"id": "web"}],
                    # Enable extended thinking / reasoning
                    "reasoning": {"effort": "xhigh"},
                }
                if self.debug:
                    dbg = json.dumps(payload, ensure_ascii=False)[:8000]
                    print(f"[debug] Request: {dbg}", file=sys.stderr)

                resp = await self.http.post(
                    OPENROUTER_URL,
                    headers=self.headers,
                    json=payload,
                    timeout=600,
                )
                if resp.status_code == 429:
                    wait = int(resp.headers.get("retry-after", 5))
                    self.spinner.update(f"Rate limited — waiting {wait}s…")
                    await asyncio.sleep(wait)
                    continue
                if resp.status_code >= 500 and attempt < retries - 1:
                    await asyncio.sleep(2 ** attempt)
                    continue

                result = resp.json()

                if self.debug:
                    dbg_r = json.dumps(result, ensure_ascii=False)[:4000]
                    print(f"[debug] Response: {dbg_r}", file=sys.stderr)

                rid = result.get("id")
                if rid:
                    await self.cost_tracker.track(rid, "opus")

                if "error" in result:
                    err = result["error"]
                    msg = err.get("message", str(err)) if isinstance(err, dict) else str(err)
                    lower = msg.lower()
                    # If tools are rejected, retry without them (fallback to JSON mode)
                    if any(t in lower for t in ["tool", "tool_choice", "function calling"]):
                        payload.pop("tools", None)
                        payload.pop("tool_choice", None)
                        resp2 = await self.http.post(
                            OPENROUTER_URL, headers=self.headers, json=payload, timeout=600
                        )
                        result = resp2.json()
                        rid2 = result.get("id")
                        if rid2:
                            await self.cost_tracker.track(rid2, "opus")
                        if "error" not in result:
                            return result
                    print(f"\n  ⚠ API error: {msg}", file=sys.stderr)
                    if attempt < retries - 1:
                        await asyncio.sleep(2)
                        continue
                    return None
                return result
            except httpx.TimeoutException:
                if attempt < retries - 1:
                    self.spinner.update(f"Timeout — retrying ({attempt + 2}/{retries})…")
                    await asyncio.sleep(2 ** attempt)
                    continue
                print("\n  ⚠ Request timed out after all retries.", file=sys.stderr)
                return None
            except Exception as e:
                print(f"\n  ⚠ Request error: {e}", file=sys.stderr)
                if self.verbose:
                    traceback.print_exc(file=sys.stderr)
                if attempt < retries - 1:
                    await asyncio.sleep(2)
                    continue
                return None
        return None

    # ── Parallel tool execution ──────────────────────────────────
    async def _execute_tools(self, tool_calls):
        async def exec_one(tc):
            name = tc["function"]["name"]
            try:
                args = json.loads(tc["function"]["arguments"])
            except (json.JSONDecodeError, TypeError):
                return {
                    "role": "tool",
                    "tool_call_id": tc["id"],
                    "content": f"Error: Invalid JSON arguments for {name}",
                }

            result_mode = args.pop("result_mode", "raw")

            brief = ""
            for key in ("path", "command", "query", "url", "pattern", "content_query", "question"):
                if key in args:
                    brief = str(args[key])[:60]
                    break
            self.spinner.update(f"⚡ {name}" + (f" → {brief}" if brief else ""))

            method_name = self.DISPATCH.get(name)
            if not method_name:
                raw = f"Unknown tool: {name}"
            else:
                method = getattr(self, method_name, None)
                if not method:
                    raw = f"Tool not implemented: {name}"
                else:
                    try:
                        raw = await method(**args)
                    except TypeError as e:
                        raw = f"Tool error ({name}): bad arguments — {e}"
                    except Exception as e:
                        raw = f"Tool error ({name}): {e}"
                        if self.verbose:
                            raw += f"\n{traceback.format_exc()}"

            # Apply result_mode: raw or summarize
            if name in ("finalize", "think"):
                final = raw
            elif result_mode and result_mode.lower() != "raw":
                self.spinner.update(f"📝 Summarizing {name}…")
                final = await smart_summarize(
                    raw, result_mode, self.headers, self.cost_tracker, self.http
                )
            else:
                final = raw

            if len(final) > 150_000:
                final = final[:150_000] + "\n\n[…truncated at 150K chars]"

            tag = "raw" if (not result_mode or result_mode.lower() == "raw") else "sum"
            print(
                f"  ⚡ {name}" + (f" → {brief}" if brief else "") + f"  [{len(final):,}ch {tag}]",
                file=sys.stderr,
            )

            return {"role": "tool", "tool_call_id": tc["id"], "content": final}

        results = await asyncio.gather(
            *[exec_one(tc) for tc in tool_calls], return_exceptions=True
        )
        processed = []
        for i, r in enumerate(results):
            if isinstance(r, BaseException):
                processed.append({
                    "role": "tool",
                    "tool_call_id": tool_calls[i]["id"],
                    "content": f"Fatal tool error: {r}",
                })
            else:
                processed.append(r)
        return processed

    # ── Display ──────────────────────────────────────────────────
    def _show_final(self, report):
        print(f"\n{'═' * 58}", file=sys.stderr)
        print("  ✅ TASK COMPLETE", file=sys.stderr)
        print(f"{'═' * 58}\n", file=sys.stderr)
        print(report)
        if self._final_files:
            print("\nKey files:", file=sys.stderr)
            for f in self._final_files:
                print(f"  - {f}", file=sys.stderr)
        if not sys.stdout.isatty():
            print(report, file=sys.stderr)

    def _show_cost_report(self):
        rpt = self.cost_tracker.report()
        total = self.cost_tracker.total_cost
        print(f"\n{'━' * 58}", file=sys.stderr)
        print(f"  Session cost: ${total:.4f}", file=sys.stderr)
        for model, d in sorted(rpt.items()):
            parts = [f"${d['cost']:.4f}", f"{d['calls']} call{'s' if d['calls']!=1 else ''}"]
            parts.append(f"{d['in']:,} in / {d['out']:,} out")
            if d.get('reasoning'):
                parts.append(f"{d['reasoning']:,} reasoning")
            if d.get('cached'):
                parts.append(f"{d['cached']:,} cached")
            print(f"    {model}: {', '.join(parts)}", file=sys.stderr)
        if not rpt:
            print("    (no stats collected)", file=sys.stderr)
        print(f"{'━' * 58}", file=sys.stderr)

    # ── Cleanup ──────────────────────────────────────────────────
    async def cleanup(self):
        self.spinner.stop()
        print("\n  ⏳ Cleaning up…", file=sys.stderr)
        self.searxng.stop()
        await self.browser.close()
        print("  ⏳ Fetching cost data…", file=sys.stderr)
        await self.cost_tracker.drain(timeout=30)
        if self.http:
            await self.http.aclose()
        self._show_cost_report()

# ═══════════════════════════════════════════════════════════════════
# CLI entry point
# ═══════════════════════════════════════════════════════════════════

def read_prompt_interactive():
    try:
        from prompt_toolkit import PromptSession
        from prompt_toolkit.key_binding import KeyBindings

        print(
            "\nEnter your prompt. Submit: Esc+Enter, F2, Ctrl+S, or Ctrl+D. Cancel: Ctrl+C.\n",
            file=sys.stderr,
        )

        kb = KeyBindings()

        @kb.add("escape", "enter")
        def _submit_esc(event):
            event.app.current_buffer.validate_and_handle()

        for key in ("f2", "f5", "f9", "c-s", "c-d"):
            @kb.add(key)
            def _submit(event):
                event.app.current_buffer.validate_and_handle()

        session = PromptSession(
            "> ",
            key_bindings=kb,
            multiline=True,
            prompt_continuation=lambda w, ln, wc: ". ",
        )
        return session.prompt()
    except KeyboardInterrupt:
        print("Cancelled.", file=sys.stderr)
        sys.exit(0)
    except Exception:
        print("\nType prompt, then Ctrl-D on a new line when done:\n", file=sys.stderr)
        lines = []
        try:
            while True:
                lines.append(input())
        except EOFError:
            pass
        except KeyboardInterrupt:
            sys.exit(0)
        return "\n".join(lines)


async def run_agent(prompt, model, oracle_model, api_key, cwd, max_loops,
                    debug, verbose, resume_id=None):
    agent = Agent(model, oracle_model, api_key, cwd, debug=debug, verbose=verbose)

    if resume_id:
        agent.thread_logger = ThreadLogger(thread_id=resume_id)
        resume_messages = agent.thread_logger.load_messages()
        meta = agent.thread_logger.load_meta()
        print(f"  ⟳ Resuming thread: {resume_id}", file=sys.stderr)
        print(f"    Original prompt: {meta.get('prompt', '(unknown)')[:80]}…", file=sys.stderr)
    else:
        agent.thread_logger = ThreadLogger()
        resume_messages = None

    thread_id = agent.thread_logger.thread_id
    print(f"  ℹ Thread ID: {thread_id}", file=sys.stderr)

    try:
        await agent.setup()
        print(f"  ✓ Model: {model}", file=sys.stderr)
        print(f"  ✓ Oracle: {oracle_model}", file=sys.stderr)
        print(f"  ✓ Agent ready\n", file=sys.stderr)
        await agent.run(prompt, max_loops=max_loops, resume_messages=resume_messages)
    except KeyboardInterrupt:
        print("\n\n  ⚡ Interrupted!", file=sys.stderr)
    except Exception as e:
        print(f"\n  ⚠ Fatal error: {e}", file=sys.stderr)
        if verbose:
            traceback.print_exc(file=sys.stderr)
    finally:
        # Final save
        if agent.thread_logger:
            agent.thread_logger.save_messages(agent.messages)
        await agent.cleanup()
        print(f"\n  ℹ Thread ID: {thread_id}", file=sys.stderr)
        print(f"    Resume with: dothething.sh --resume {thread_id}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(
        prog="dothething",
        description="Autonomous AI agent — https://dotheth.ing",
        usage="dothething [--fast] [--oraclepro] [--resume ID] [prompt ...]",
    )
    parser.add_argument("--fast", action="store_true", help="Use claude-opus-4.6-fast")
    parser.add_argument("--oraclepro", action="store_true", help="Use gpt-5.4-pro for oracle (default: gpt-5.4)")
    parser.add_argument("--prompt", type=str, default=None, help="Inline prompt text")
    parser.add_argument("--cwd", type=str, default=".", help="Working directory for relative paths")
    parser.add_argument("--max-loops", type=int, default=MAX_LOOPS, help=f"Maximum agent loops (default: {MAX_LOOPS})")
    parser.add_argument("--resume", type=str, default=None, metavar="THREAD_ID", help="Resume a previous thread")
    parser.add_argument("--verbose", action="store_true", help="Verbose error traces")
    parser.add_argument("--debug", action="store_true", help="Debug-level API payload logging")
    parser.add_argument("positional_prompt", nargs="*", help="Task prompt (omit for interactive editor)")
    args = parser.parse_args()

    api_key = os.environ.get("OPENROUTER_API_KEY")
    if not api_key:
        print("Error: OPENROUTER_API_KEY environment variable not set.", file=sys.stderr)
        sys.exit(1)

    model = OPUS_FAST if args.fast else OPUS
    oracle_model = ORACLE_PRO if args.oraclepro else ORACLE_DEFAULT
    cwd = str(Path(args.cwd).expanduser().resolve())

    if args.resume:
        prompt = "(resumed)"
    elif args.prompt:
        prompt = args.prompt
    elif args.positional_prompt:
        prompt = " ".join(args.positional_prompt)
    elif sys.stdin.isatty():
        prompt = read_prompt_interactive()
    else:
        prompt = sys.stdin.read()

    prompt = prompt.strip()
    if not prompt and not args.resume:
        print("Error: Empty prompt.", file=sys.stderr)
        sys.exit(1)

    print(f"\n{'─' * 58}", file=sys.stderr)
    print("  dothething | https://dotheth.ing", file=sys.stderr)
    print(f"{'─' * 58}\n", file=sys.stderr)

    try:
        asyncio.run(run_agent(
            prompt=prompt,
            model=model,
            oracle_model=oracle_model,
            api_key=api_key,
            cwd=cwd,
            max_loops=args.max_loops,
            debug=args.debug,
            verbose=args.verbose,
            resume_id=args.resume,
        ))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
PYTHON_AGENT

exec python "$BASE/agent.py" "$@"