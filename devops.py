#!/usr/bin/env python3
"""Azure DevOps sprint board helper for the funcoder.devops-board plugin.

Every command prints one JSON object on stdout. Failures that the board can
explain are returned as {"error": "..."} with exit code 0, so the QML side
only ever has to parse JSON. Secrets and edit payloads arrive as a single
JSON line on stdin, never in argv.

Commands:
  status                       connection, team and token state
  connect                      stdin {"org", "token"}; verifies, saves, lists teams
  disconnect                   forget the token and connection
  teams                        teams in every project the token can see
  set-team <team-id>           choose the team whose sprint is shown
  board [--iteration ID] [--cached] [--backlog]
                               iteration tree (epics, features, stories,
                               bugs and tasks under the sprint) or the full
                               team backlog when --backlog is set
  item <id>                    one work item with everything the editor needs
  update <id>                  stdin {"rev", "changes": {...}}; saves edits
  comment <id>                 stdin {"text"}; adds a discussion comment
  pref hideClosed on|off       remember whether closed sprints and items are hidden
  demo on|off                  serve built-in sample data (no Azure access)
  launcher                     write the .desktop entry that lists the board in Apps

The token lives in the desktop keyring (secret-tool), keyed by organization.
AZURE_DEVOPS_EXT_PAT is used when the keyring has nothing.
"""

import base64
import html
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from html.parser import HTMLParser

APP = "funcoder-devops-board"
CONFIG_DIR = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"), APP)
CONFIG_FILE = os.path.join(CONFIG_DIR, "config.json")
CACHE_DIR = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), APP)
API = "7.1"
TIMEOUT = 25
# The socket timeout only bounds a single quiet stretch, so a response that
# keeps trickling in could otherwise run forever. These bound the whole thing:
# total time, total bytes, and the shape of what is handed to the shell.
DEADLINE = 90
MAX_BODY_BYTES = 8 * 1024 * 1024
MAX_ERROR_BYTES = 64 * 1024
CHUNK = 64 * 1024
MAX_ITEMS = 5000
MAX_STRING = 1000 * 1000
MAX_NODES = 200 * 1000
MAX_DEPTH = 32

POINTS_FIELDS = [
    "Microsoft.VSTS.Scheduling.StoryPoints",  # Agile
    "Microsoft.VSTS.Scheduling.Effort",       # Scrum
    "Microsoft.VSTS.Scheduling.Size",         # CMMI
]
REMAINING = "Microsoft.VSTS.Scheduling.RemainingWork"
ACCEPTANCE = "Microsoft.VSTS.Common.AcceptanceCriteria"
REPRO = "Microsoft.VSTS.TCM.ReproSteps"
PRIORITY = "Microsoft.VSTS.Common.Priority"
ORDER_FIELDS = ["Microsoft.VSTS.Common.BacklogPriority", "Microsoft.VSTS.Common.StackRank"]
CHILD = "System.LinkTypes.Hierarchy-Forward"
PARENT = "System.LinkTypes.Hierarchy-Reverse"

# State categories from the process, collapsed to what the board draws.
CATEGORY = {
    "Proposed": "todo",
    "InProgress": "doing",
    "Resolved": "doing",
    "Completed": "done",
    "Removed": "removed",
}


class Failure(Exception):
    pass


def emit(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False))
    sys.stdout.write("\n")
    sys.stdout.flush()


def read_stdin_json():
    line = sys.stdin.readline()
    try:
        data = json.loads(line or "{}")
    except json.JSONDecodeError:
        raise Failure("Invalid input")
    if not isinstance(data, dict):
        raise Failure("Invalid input")
    return data


# ---- config, cache and token ------------------------------------------------


def load_json(path, default):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def save_json(path, data, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def load_config():
    cfg = load_json(CONFIG_FILE, {})
    return cfg if isinstance(cfg, dict) else {}


def save_config(cfg):
    save_json(CONFIG_FILE, cfg)


def cache_path(name):
    safe = re.sub(r"[^A-Za-z0-9_.-]+", "_", name)
    return os.path.join(CACHE_DIR, safe + ".json")


def cached(name, max_age, fetch):
    """Return a cached JSON value younger than max_age seconds, else refetch."""
    path = cache_path(name)
    try:
        if time.time() - os.path.getmtime(path) < max_age:
            value = load_json(path, None)
            if value is not None:
                return value
    except OSError:
        pass
    value = fetch()
    save_json(path, value, 0o600)
    return value


def token_lookup(org):
    try:
        out = subprocess.run(
            ["secret-tool", "lookup", "service", APP, "org", org],
            capture_output=True, text=True, timeout=10,
        )
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        pass
    return os.environ.get("AZURE_DEVOPS_EXT_PAT", "").strip()


def token_store(org, token):
    try:
        out = subprocess.run(
            ["secret-tool", "store", "--label", "Azure DevOps board (%s)" % org, "service", APP, "org", org],
            input=token, capture_output=True, text=True, timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise Failure("Could not save the token to the keyring: %s" % exc)
    if out.returncode != 0:
        raise Failure("Could not save the token to the keyring: %s" % (out.stderr.strip() or "secret-tool failed"))


def token_clear(org):
    try:
        subprocess.run(["secret-tool", "clear", "service", APP, "org", org], capture_output=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        pass


def normalize_org(org_input, project_input):
    """Accept an org name, org URL or any board URL; return (org_url, project)."""
    org = (org_input or "").strip().rstrip("/")
    project = (project_input or "").strip()
    if not org:
        raise Failure("Enter your organization, e.g. https://dev.azure.com/contoso")
    if "://" not in org:
        if "/" in org or "." in org:
            org = "https://" + org
        else:
            return "https://dev.azure.com/" + org, project
    parsed = urllib.parse.urlparse(org)
    parts = [urllib.parse.unquote(p) for p in parsed.path.split("/") if p]
    host = parsed.netloc.lower()
    if host == "dev.azure.com" and parts:
        base = "https://dev.azure.com/" + urllib.parse.quote(parts[0])
        if not project and len(parts) > 1 and not parts[1].startswith("_"):
            project = parts[1]
        return base, project
    if host.endswith(".visualstudio.com"):
        base = "https://" + host
        if not project and parts and not parts[0].startswith("_"):
            project = parts[0]
        return base, project
    # Azure DevOps Server: take the URL as given.
    return org, project


# ---- HTTP ---------------------------------------------------------------------


def read_limited(resp, limit, deadline, what="Azure DevOps"):
    """Read a response body up to `limit` bytes and no longer than the deadline."""
    chunks, total = [], 0
    # read1 hands back whatever has arrived instead of waiting for a full
    # chunk, so a response delivered a few bytes at a time still hits the
    # deadline check rather than trickling on indefinitely.
    read = getattr(resp, "read1", None) or resp.read
    while True:
        if time.monotonic() > deadline:
            raise Failure("%s took too long to answer" % what)
        try:
            chunk = read(min(CHUNK, limit + 1 - total))
        except TimeoutError:
            raise Failure("%s took too long to answer" % what)
        if not chunk:
            break
        total += len(chunk)
        if total > limit:
            raise Failure("%s sent more data than this board will read" % what)
        chunks.append(chunk)
    return b"".join(chunks)


def check_shape(data, depth=0, budget=None):
    """Refuse a payload with absurd counts, lengths or nesting before it is used.

    Nothing is truncated: a board that silently dropped half a description
    could write the short version back.
    """
    if budget is None:
        budget = [MAX_NODES]
    budget[0] -= 1
    if budget[0] < 0:
        raise Failure("Azure DevOps returned more data than this board can show")
    if depth > MAX_DEPTH:
        raise Failure("Azure DevOps returned a deeply nested answer this board won't read")
    if isinstance(data, str):
        if len(data) > MAX_STRING:
            raise Failure("Azure DevOps returned an oversized field this board won't show")
    elif isinstance(data, list):
        if len(data) > MAX_ITEMS:
            raise Failure("Azure DevOps returned more than %d items; narrow the query" % MAX_ITEMS)
        for item in data:
            check_shape(item, depth + 1, budget)
    elif isinstance(data, dict):
        if len(data) > MAX_ITEMS:
            raise Failure("Azure DevOps returned an answer with too many fields")
        for key, value in data.items():
            check_shape(key, depth + 1, budget)
            check_shape(value, depth + 1, budget)
    return data


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """urllib would replay the Authorization header (the token) to wherever a
    redirect points. Azure DevOps only redirects when it wants a browser
    sign-in, so treat any redirect as a rejected token instead of following it."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, 401, "redirected to sign-in", headers, fp)


_OPENER = urllib.request.build_opener(_NoRedirect)


def check_secure(url):
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme == "https":
        return
    if parsed.scheme == "http" and parsed.hostname in ("localhost", "127.0.0.1", "::1"):
        return
    raise Failure("Use an https:// organization URL; the token would otherwise travel unencrypted")


class Client:
    def __init__(self, org, project, token):
        self.org = org
        self.project = project
        self.token = token

    def url(self, path, params=None, project=True, team=None):
        parts = [self.org]
        if project:
            parts.append(urllib.parse.quote(self.project, safe=""))
        if team:
            parts.append(urllib.parse.quote(team, safe=""))
        url = "/".join(parts) + path
        query = {"api-version": API}
        query.update(params or {})
        return url + ("&" if "?" in url else "?") + urllib.parse.urlencode(query)

    def request(self, method, url, body=None, content_type="application/json", deadline=None):
        deadline = deadline or (time.monotonic() + DEADLINE)
        auth = base64.b64encode((":" + self.token).encode()).decode()
        headers = {"Authorization": "Basic " + auth, "Accept": "application/json"}
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = content_type
        check_secure(url)
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with _OPENER.open(req, timeout=TIMEOUT) as resp:
                raw = read_limited(resp, MAX_BODY_BYTES, deadline)
                ctype = resp.headers.get("Content-Type", "")
        except urllib.error.HTTPError as exc:
            detail = error_detail(exc, deadline)
            # Some resources are still in preview and refuse a released
            # api-version; ask again with "-preview" appended.
            if exc.code == 400 and "-preview" in detail and "api-version=" in url and "-preview" not in url:
                return self.request(method, re.sub(r"(api-version=[0-9.]+)", r"\1-preview", url),
                                    body, content_type, deadline)
            raise Failure(http_message(exc.code, detail))
        except urllib.error.URLError as exc:
            raise Failure("Can't reach %s (%s)" % (urllib.parse.urlparse(url).netloc, exc.reason))
        except TimeoutError:
            raise Failure("Azure DevOps took too long to answer")
        if "json" not in ctype:
            # A sign-in page instead of JSON means the token was not accepted.
            raise Failure("Token rejected: Azure DevOps answered with a sign-in page")
        return check_shape(json.loads(raw.decode("utf-8") or "{}"))

    def get(self, path, params=None, project=True, team=None):
        return self.request("GET", self.url(path, params, project, team))


def error_detail(exc, deadline=None):
    try:
        raw = read_limited(exc, MAX_ERROR_BYTES, deadline or (time.monotonic() + TIMEOUT))
        return (json.loads(raw.decode("utf-8")).get("message") or "")[:2000]
    except Exception:
        return ""


def http_message(code, detail):
    if code in (401, 203):
        return "Token rejected: it may have expired or belong to another organization"
    if code == 403:
        return detail or "The token lacks permission (needs Work Items: Read & write, Project and Team: Read)"
    if code == 404:
        return detail or "Not found"
    if code == 412 or "TF26071" in detail or ("rev" in detail.lower() and code == 400):
        return "Someone else changed this item since you opened it. Reload to see their changes."
    return detail or "Azure DevOps error %d" % code


def client_from_config(cfg=None, need_project=True):
    cfg = cfg or load_config()
    if not cfg.get("org"):
        raise Failure("Not connected")
    if need_project and not cfg.get("project"):
        raise Failure("Choose a team")
    token = token_lookup(cfg["org"])
    if not token:
        raise Failure("No token saved for %s" % cfg["org"])
    return Client(cfg["org"], cfg.get("project", ""), token)


# ---- HTML <-> editable text -----------------------------------------------------
#
# Azure DevOps stores rich text as HTML. The editor works on light markdown:
# paragraphs, "- " and "1. " lists, "#" headings, **bold**, *italic* and
# [links](url). Images and tables can't survive that round trip, so fields
# holding them are shown read-only.


class _ToText(HTMLParser):
    BLOCKS = {"div", "p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "tr", "blockquote", "pre", "table"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.out = []
        self.lists = []
        self.links = []
        self.pre = 0

    def text(self):
        return "".join(self.out)

    def newline(self):
        s = self.text()
        if s and not s.endswith("\n"):
            self.out.append("\n")

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "br":
            self.out.append("\n")
        elif tag in ("ul", "ol"):
            self.newline()
            self.lists.append([tag, 0])
        elif tag == "li":
            self.newline()
            indent = "  " * max(0, len(self.lists) - 1)
            if self.lists and self.lists[-1][0] == "ol":
                self.lists[-1][1] += 1
                self.out.append("%s%d. " % (indent, self.lists[-1][1]))
            else:
                self.out.append(indent + "- ")
        elif tag in ("h1", "h2", "h3", "h4", "h5", "h6"):
            self.newline()
            self.out.append("#" * min(3, int(tag[1])) + " ")
        elif tag in ("b", "strong"):
            self.out.append("**")
        elif tag in ("i", "em"):
            self.out.append("*")
        elif tag == "a":
            self.links.append((a.get("href") or "", len(self.out)))
        elif tag == "pre":
            self.newline()
            self.pre += 1
        elif tag in ("td", "th"):
            self.out.append(" | ")
        elif tag == "img":
            self.out.append("[image]")
        elif tag in self.BLOCKS:
            self.newline()

    def handle_endtag(self, tag):
        if tag in ("ul", "ol"):
            if self.lists:
                self.lists.pop()
            self.newline()
        elif tag in ("b", "strong"):
            self.out.append("**")
        elif tag in ("i", "em"):
            self.out.append("*")
        elif tag == "a" and self.links:
            href, start = self.links.pop()
            label = "".join(self.out[start:]).strip()
            del self.out[start:]
            if href and label and label != href and not href.startswith("#"):
                self.out.append("[%s](%s)" % (label, href))
            else:
                self.out.append(label or href)
        elif tag == "p":
            self.newline()
            self.out.append("\n")
        elif tag == "pre":
            self.pre = max(0, self.pre - 1)
            self.newline()
        elif tag in self.BLOCKS:
            self.newline()

    def handle_data(self, data):
        if self.pre:
            self.out.append(data)
            return
        data = re.sub(r"[ \t\r\n\f]+", " ", data.replace("\xa0", " "))
        s = self.text()
        if data == " " and (not s or s.endswith("\n") or s.endswith(" ")):
            return
        if s.endswith("\n") or not s:
            data = data.lstrip()
        self.out.append(data)


def html_to_text(value):
    value = value or ""
    if "<" not in value:
        return html.unescape(value).strip()
    parser = _ToText()
    parser.feed(value)
    parser.close()
    lines = [line.rstrip() for line in parser.text().split("\n")]
    return re.sub(r"\n{3,}", "\n\n", "\n".join(lines)).strip()


def is_rich(value):
    return bool(re.search(r"<\s*(img|table|pre|code|iframe|video)\b", value or "", re.I))


def _inline(text):
    s = html.escape(text, quote=False)
    s = re.sub(r"\[([^\]]+)\]\((https?://[^)\s]+)\)",
               lambda m: '<a href="%s">%s</a>' % (html.escape(m.group(2)), m.group(1)), s)
    s = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", s)
    s = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])", r"<i>\1</i>", s)
    return s


def text_to_html(text):
    lines = (text or "").replace("\r\n", "\n").split("\n")
    out = []
    lst = None
    for line in lines:
        bullet = re.match(r"^\s*[-*]\s+(.*)$", line)
        number = re.match(r"^\s*\d+[.)]\s+(.*)$", line)
        kind = "ul" if bullet else "ol" if number else None
        if lst and kind != lst:
            out.append("</%s>" % lst)
            lst = None
        if kind:
            if not lst:
                out.append("<%s>" % kind)
                lst = kind
            out.append("<li>%s</li>" % _inline((bullet or number).group(1)))
            continue
        heading = re.match(r"^(#{1,3})\s+(.*)$", line)
        if heading:
            n = len(heading.group(1))
            out.append("<h%d>%s</h%d>" % (n, _inline(heading.group(2)), n))
        elif line.strip() == "":
            out.append("<div><br></div>")
        else:
            out.append("<div>%s</div>" % _inline(line))
    if lst:
        out.append("</%s>" % lst)
    while out and out[-1] == "<div><br></div>":
        out.pop()
    return "".join(out)


# ---- shaping work items -----------------------------------------------------------


def person(value):
    if isinstance(value, dict):
        return {"name": value.get("displayName") or "", "email": value.get("uniqueName") or ""}
    if isinstance(value, str) and value:
        m = re.match(r"^(.*?)\s*<([^>]+)>$", value)
        if m:
            return {"name": m.group(1), "email": m.group(2)}
        return {"name": value, "email": ""}
    return {"name": "", "email": ""}


def number(value):
    try:
        f = float(value)
    except (TypeError, ValueError):
        return None
    return int(f) if f.is_integer() else round(f, 2)


def type_states(client, wtype):
    def fetch():
        data = client.get("/_apis/wit/workitemtypes/%s/states" % urllib.parse.quote(wtype, safe=""))
        return [{"name": s.get("name"), "category": CATEGORY.get(s.get("category"), "todo")}
                for s in data.get("value", [])]
    return cached("states-%s-%s-%s" % (client.org, client.project, wtype), 86400, fetch)


def type_fields(client, wtype):
    def fetch():
        data = client.get("/_apis/wit/workitemtypes/%s/fields" % urllib.parse.quote(wtype, safe=""))
        return [f.get("referenceName") for f in data.get("value", [])]
    return cached("fields-%s-%s-%s" % (client.org, client.project, wtype), 86400, fetch)


def category_of(client, wtype, state, memo):
    if wtype not in memo:
        try:
            memo[wtype] = {s["name"]: s["category"] for s in type_states(client, wtype)}
        except Failure:
            memo[wtype] = {}
    known = memo[wtype].get(state)
    if known:
        return known
    s = (state or "").lower()
    if s in ("done", "closed", "resolved", "completed"):
        return "done"
    if s in ("removed", "cut"):
        return "removed"
    if s in ("new", "to do", "proposed", "approved", "open"):
        return "todo"
    return "doing"


def order_key(fields):
    for f in ORDER_FIELDS:
        if fields.get(f) is not None:
            return float(fields[f])
    return None


def by_order(item):
    return (item["order"] is None, item["order"] or 0, item["id"])


def batch_items(client, ids):
    items = {}
    ids = list(dict.fromkeys(ids))
    for i in range(0, len(ids), 200):
        chunk = ids[i:i + 200]
        data = client.request("POST", client.url("/_apis/wit/workitemsbatch"),
                              {"ids": chunk, "errorPolicy": "omit", "$expand": "relations"})
        for wi in data.get("value", []) or []:
            if wi:
                items[wi["id"]] = wi
    return items


# ---- commands ---------------------------------------------------------------------


def cmd_status(args):
    cfg = load_config()
    if cfg.get("demo"):
        return {"connected": True, "demo": True, "org": "https://dev.azure.com/demo", "project": "Demo",
                "team": {"id": "demo", "name": "Phoenix Team", "project": "Demo"}, "user": DEMO_ME,
                "hideClosed": bool(cfg.get("hideClosed"))}
    has_token = bool(cfg.get("org") and token_lookup(cfg["org"]))
    team = cfg.get("team") if cfg.get("project") else None
    return {
        "connected": has_token,
        "org": cfg.get("org", ""),
        "project": cfg.get("project", "") if team else "",
        "team": team or None,
        "user": cfg.get("user") or None,
        "hasToken": has_token,
        "hideClosed": bool(cfg.get("hideClosed")),
        "showBacklog": bool(cfg.get("showBacklog")),
    }


def all_teams(client):
    """Every team the token can see, across all projects."""
    try:
        data = client.get("/_apis/teams", {"api-version": "7.1-preview.3", "$top": "1000"}, project=False)
        teams = [{"id": t["id"], "name": t["name"], "projectId": t.get("projectId", ""),
                  "project": t.get("projectName", "")} for t in data.get("value", [])]
    except Failure:
        # Fall back to walking the projects one at a time.
        teams = []
        projects = client.get("/_apis/projects", {"$top": "500"}, project=False).get("value", [])
        for proj in projects:
            data = client.get("/_apis/projects/%s/teams" % proj["id"], {"$top": "500"}, project=False)
            teams += [{"id": t["id"], "name": t["name"], "projectId": proj["id"], "project": proj["name"]}
                      for t in data.get("value", [])]
    if any(not t["project"] for t in teams):
        projects = client.get("/_apis/projects", {"$top": "500"}, project=False).get("value", [])
        names = {p["id"]: p["name"] for p in projects}
        for t in teams:
            t["project"] = t["project"] or names.get(t["projectId"], "")
        teams = [t for t in teams if t["project"]]
    return sorted(teams, key=lambda t: (t["name"].lower(), t["project"].lower()))


def cmd_connect(args):
    data = read_stdin_json()
    org, project_hint = normalize_org(data.get("org"), "")
    cfg = load_config()
    token = (data.get("token") or "").strip()
    if not token and cfg.get("org") == org:
        token = token_lookup(org)
    if not token:
        raise Failure("Paste a personal access token")
    client = Client(org, "", token)
    conn = client.get("/_apis/connectionData", {"api-version": "7.1-preview"}, project=False)
    user = conn.get("authenticatedUser") or {}
    props = user.get("properties") or {}
    account = (props.get("Account") or {}).get("$value") or ""
    me = {"name": user.get("providerDisplayName") or "", "email": account}
    teams = all_teams(client)
    if not teams:
        raise Failure("The token works, but it can't see any teams. Give it the Project and Team (Read) scope.")
    token_store(org, token)

    # Keep the team chosen before if it's still visible; a lone team is chosen for you.
    team = None
    if cfg.get("org") == org and cfg.get("team"):
        team = next((t for t in teams if t["id"] == cfg["team"].get("id")), None)
    if not team and len(teams) == 1:
        team = teams[0]
    save_config({"org": org, "project": team["project"] if team else "", "team": team, "user": me,
                 "hideClosed": bool(cfg.get("hideClosed"))})
    return {"ok": True, "org": org, "project": team["project"] if team else "", "user": me, "team": team,
            "teams": teams, "projectHint": project_hint}


def cmd_disconnect(args):
    cfg = load_config()
    if cfg.get("org"):
        token_clear(cfg["org"])
    save_config({"org": cfg.get("org", ""), "hideClosed": bool(cfg.get("hideClosed"))})
    return {"ok": True}


def cmd_teams(args):
    cfg = load_config()
    if cfg.get("demo"):
        return {"teams": DEMO_TEAMS}
    return {"teams": all_teams(client_from_config(cfg, need_project=False))}


def cmd_set_team(args):
    if not args:
        raise Failure("Missing team id")
    cfg = load_config()
    if cfg.get("demo"):
        return {"ok": True}
    teams = all_teams(client_from_config(cfg, need_project=False))
    match = next((t for t in teams if t["id"] == args[0]), None)
    if not match:
        raise Failure("That team is no longer visible to your token")
    cfg["team"] = match
    cfg["project"] = match["project"]
    save_config(cfg)
    return {"ok": True, "team": match, "project": match["project"]}


def iterations(client, team):
    data = client.get("/_apis/work/teamsettings/iterations", team=team["id"])
    out = []
    for it in data.get("value", []):
        attrs = it.get("attributes") or {}
        out.append({
            "id": it["id"],
            "name": it.get("name"),
            "path": it.get("path"),
            "start": attrs.get("startDate"),
            "finish": attrs.get("finishDate"),
            "timeFrame": attrs.get("timeFrame") or "",
        })
    return out


def cmd_board(args):
    iteration_id = None
    use_cache = False
    backlog = False
    i = 0
    while i < len(args):
        if args[i] == "--iteration" and i + 1 < len(args):
            iteration_id = args[i + 1]
            i += 1
        elif args[i] == "--cached":
            use_cache = True
        elif args[i] == "--backlog":
            backlog = True
        i += 1

    cfg = load_config()
    if cfg.get("demo"):
        return demo_board(iteration_id)
    team = cfg.get("team")
    if not team:
        raise Failure("Choose a team")
    mode = "backlog" if backlog else ("iteration:%s" % iteration_id if iteration_id else "current")
    key = "board-%s-%s-%s-%s" % (cfg.get("org"), cfg.get("project"), team["id"], mode)
    if use_cache:
        board = load_json(cache_path(key), None)
        return board if board else {"cacheMiss": True}

    client = client_from_config(cfg)
    its = iterations(client, team)
    if not its:
        raise Failure("%s has no sprints selected. Pick them in the team's settings." % team["name"])
    current = None
    if iteration_id:
        current = next((it for it in its if it["id"] == iteration_id), None)
    if not current:
        current = next((it for it in its if it["timeFrame"].lower() == "current"), None)
    if not current:
        past = [it for it in its if it["timeFrame"].lower() == "past"]
        current = past[-1] if past else its[0]

    if backlog:
        return build_backlog(client, cfg, team, its, current, key)

    rels = client.get("/_apis/work/teamsettings/iterations/%s/workitems" % current["id"],
                      {"api-version": "7.1-preview.1"}, team=team["id"]).get("workItemRelations", [])
    parent_of = {}
    seed_ids = []
    in_sprint_ids = []
    for r in rels:
        target = (r.get("target") or {}).get("id")
        source = (r.get("source") or {}).get("id")
        if target:
            seed_ids.append(target)
            in_sprint_ids.append(target)
        if source:
            seed_ids.append(source)
        if r.get("rel") == CHILD and source and target:
            parent_of[target] = source

    # Walk upward. The iteration endpoint only gives direct parent edges, so
    # we expand each ancestor's relations too until there are no more parents.
    items = batch_items(client, seed_ids) if seed_ids else {}
    frontier = [wid for wid in seed_ids if parent_of.get(wid) and parent_of[wid] not in items]
    while frontier:
        batch = batch_items(client, frontier)
        items.update(batch)
        next_frontier = []
        for wid, wi in batch.items():
            for rel in (wi.get("relations") or []):
                if rel.get("rel") != PARENT:
                    continue
                pid = int(rel["url"].rstrip("/").split("/")[-1])
                if wid not in parent_of:
                    parent_of[wid] = pid
                if pid not in items:
                    next_frontier.append(pid)
        frontier = [p for p in next_frontier if p not in items]

    return shape_board(client, cfg, team, its, current, items, parent_of, set(in_sprint_ids), key,
                       extra_key=("board-%s-%s-%s-%s" % (cfg.get("org"), cfg.get("project"), team["id"], str(current["id"]))) if not iteration_id else None)


def build_backlog(client, cfg, team, its, current, key):
    """Pull every active Epics/Features/Stories/Bugs/Tasks in the project via
    WIQL, then build the hierarchy from their relations. Items in the team's
    current sprint are flagged so the QML can badge them."""
    # Closed-state categories are derived per process, so we use a
    # well-known taxonomy of "active" states. Anything in `Removed` state is
    # filtered out by category after the fetch.
    active_states = ("New", "To Do", "Active", "Resolved", "In Progress",
                     "Proposed", "Approved", "Committed", "Done")
    active_clause = ", ".join("'%s'" % s for s in active_states)
    wiql = ("SELECT [System.Id] FROM WorkItems "
            "WHERE [System.TeamProject] = @project "
            "AND [System.WorkItemType] IN "
            "('Epic','Feature','User Story','Bug','Task') "
            "AND [System.State] IN (%s) "
            "ORDER BY [Microsoft.VSTS.Common.BacklogPriority], [System.Id]"
            % active_clause)
    # WIQL needs the project ID in the URL (names with spaces get a generic
    # 404) and a stable api-version (preview versions return 404 too).
    project_id = (team.get("projectId") or "").strip()
    org_prefix = cfg["org"] + (("/" + urllib.parse.quote(project_id, safe="")) if project_id else "")
    wiql_url = org_prefix + "/_apis/wit/wiql?api-version=7.1&$top=5000"
    query = client.request("POST", wiql_url, {"query": wiql})
    ids = [r["id"] for r in query.get("workItems", []) or []]
    items = batch_items(client, ids) if ids else {}

    in_sprint_ids = set()
    # Try the iteration endpoint for the current sprint just to know which
    # items live there. Falls back to an empty set if the sprint is also empty.
    if current and current.get("id"):
        try:
            rels = client.get(
                "/_apis/work/teamsettings/iterations/%s/workitems" % current["id"],
                {"api-version": "7.1-preview.1"}, team=team["id"]
            ).get("workItemRelations", [])
            for r in rels:
                t = (r.get("target") or {}).get("id")
                if t:
                    in_sprint_ids.add(t)
        except Failure:
            pass

    # Build parent_of from each item's relations field. WIQL doesn't include
    # relations, but batch_items requests them via $expand=relations.
    parent_of = {}
    for wid, wi in items.items():
        for rel in wi.get("relations") or []:
            if rel.get("rel") != PARENT:
                continue
            pid = int(rel["url"].rstrip("/").split("/")[-1])
            if wid not in parent_of:
                parent_of[wid] = pid

    # If a parent isn't in our fetched set, fetch it now (so an Epic above a
    # Story still shows). Continue walking until the chain ends.
    fetched = set(items.keys())
    frontier = [pid for pid in parent_of.values() if pid not in fetched]
    while frontier:
        batch = batch_items(client, frontier)
        items.update(batch)
        new_parents = {}
        for wid, wi in batch.items():
            for rel in wi.get("relations") or []:
                if rel.get("rel") != PARENT:
                    continue
                pid = int(rel["url"].rstrip("/").split("/")[-1])
                if wid not in parent_of:
                    parent_of[wid] = pid
                if pid not in items and pid not in new_parents:
                    new_parents[pid] = wid
        fetched = set(items.keys())
        frontier = [pid for pid in new_parents if pid not in fetched]

    # Tag the current "viewing iteration" so the QML can badge the rows.
    board = shape_board(client, cfg, team, its, current, items, parent_of, in_sprint_ids, key)
    board["backlog"] = True
    return board


def shape_board(client, cfg, team, its, current, items, parent_of, in_sprint, key, extra_key=None):
    memo = {}

    def shape(wi):
        f = wi.get("fields", {})
        wtype = f.get("System.WorkItemType", "")
        state = f.get("System.State", "")
        assignee = person(f.get("System.AssignedTo"))
        points = next((number(f[p]) for p in POINTS_FIELDS if f.get(p) is not None), None)
        return {
            "id": wi["id"],
            "type": wtype,
            "title": f.get("System.Title", ""),
            "state": state,
            "category": category_of(client, wtype, state, memo),
            "assignedTo": assignee["name"],
            "assignedEmail": assignee["email"],
            "points": points,
            "remaining": number(f.get(REMAINING)),
            "tags": [t.strip() for t in (f.get("System.Tags") or "").split(";") if t.strip()],
            "order": order_key(f),
            "inSprint": wi["id"] in in_sprint,
        }

    shaped = {wid: shape(wi) for wid, wi in items.items()}
    # Build a tree of {item: [children]} for everything that has a parent in
    # our set. Roots are the parents we never found a parent for.
    children_of = {}
    for wid in shaped:
        if shaped[wid]["category"] == "removed":
            continue
        p = parent_of.get(wid)
        if p in shaped:
            children_of.setdefault(p, []).append(wid)

    def build(wid):
        ordered = sorted(children_of.get(wid, []),
                         key=lambda c: (shaped[c]["order"] is None, shaped[c]["order"] or 0, shaped[c]["id"]))
        node = dict(shaped[wid], children=[build(c) for c in ordered])
        # "tasks" stays as a synonym for direct children that are Tasks, so
        # the progress bar and stats still count them without re-walking.
        node["tasks"] = [dict(c, children=[]) for c in node["children"] if c["type"] == "Task"]
        return node

    top_ids = [wid for wid in shaped
               if shaped[wid]["category"] != "removed" and parent_of.get(wid) not in shaped]
    top_ids.sort(key=lambda wid: (shaped[wid]["order"] is None, shaped[wid]["order"] or 0, shaped[wid]["id"]))
    rows = [build(wid) for wid in top_ids]

    # Tasks whose parent isn't in our set (wasn't fetched, or its parent was
    # removed) get their own bucket so they aren't dropped on the floor.
    loose_ids = [c for parent, kids in children_of.items() for c in kids
                 if shaped.get(c, {}).get("type") == "Task"
                 and shaped.get(c, {}).get("category") != "removed"
                 and parent_of.get(c) not in shaped]
    if loose_ids:
        loose_ids = list(dict.fromkeys(loose_ids))
        loose_ids.sort(key=lambda wid: (shaped[wid]["order"] is None, shaped[wid]["order"] or 0, shaped[wid]["id"]))
        rows.append({"id": 0, "type": "", "title": "Tasks without a story", "state": "", "category": "",
                     "assignedTo": "", "assignedEmail": "", "points": None, "remaining": None, "tags": [],
                     "inSprint": True, "order": None, "children": [],
                     "tasks": [dict(shaped[wid], children=[], tasks=[]) for wid in loose_ids]})

    board = {
        "org": cfg["org"],
        "project": cfg["project"],
        "team": team,
        "user": cfg.get("user"),
        "iteration": current,
        "iterations": its,
        "rows": rows,
        "fetchedAt": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    }
    save_json(cache_path(key), board, 0o600)
    # Mirror under the legacy "current" key for callers that haven't been
    # updated to the new mode tag.
    if not key.endswith("-current") and not key.endswith("-backlog"):
        legacy_key = key.rsplit("-", 1)[0] + "-current"
        if not os.path.exists(cache_path(legacy_key)):
            save_json(cache_path(legacy_key), board, 0o600)
    if extra_key:
        save_json(cache_path(extra_key), board, 0o600)
    return board


def team_members(client, team):
    def fetch():
        data = client.get("/_apis/projects/%s/teams/%s/members" % (
            urllib.parse.quote(client.project, safe=""), urllib.parse.quote(team["id"], safe="")),
            {"$top": "500"}, project=False)
        out = []
        for m in data.get("value", []):
            ident = m.get("identity") or {}
            if ident.get("isContainer"):
                continue
            out.append({"name": ident.get("displayName", ""), "email": ident.get("uniqueName", "")})
        return sorted(out, key=lambda p: p["name"].lower())
    return cached("members-%s-%s" % (client.org, team["id"]), 86400, fetch)


def cmd_item(args):
    if not args:
        raise Failure("Missing work item id")
    wid = int(args[0])
    cfg = load_config()
    if cfg.get("demo"):
        return demo_item(wid)
    client = client_from_config(cfg)
    wi = client.get("/_apis/wit/workitems/%d" % wid, {"$expand": "relations"})
    f = wi.get("fields", {})
    wtype = f.get("System.WorkItemType", "")
    fields = set(type_fields(client, wtype))
    states = type_states(client, wtype)

    body_field = REPRO if REPRO in fields and wtype == "Bug" else "System.Description"
    points_field = next((p for p in POINTS_FIELDS if p in fields), None)

    related = []
    parent_id = None
    for rel in wi.get("relations") or []:
        if rel.get("rel") in (CHILD, PARENT):
            rid = int(rel["url"].rstrip("/").split("/")[-1])
            if rel["rel"] == PARENT:
                parent_id = rid
            related.append(rid)
    linked = batch_items(client, related) if related else {}
    memo = {}

    def brief(rid):
        lf = linked.get(rid, {}).get("fields", {})
        return {
            "id": rid,
            "type": lf.get("System.WorkItemType", ""),
            "title": lf.get("System.Title", "#%d" % rid),
            "state": lf.get("System.State", ""),
            "category": category_of(client, lf.get("System.WorkItemType", ""), lf.get("System.State", ""), memo),
            "assignedTo": person(lf.get("System.AssignedTo"))["name"],
            "remaining": number(lf.get(REMAINING)),
        }

    comments = []
    try:
        cdata = client.get("/_apis/wit/workItems/%d/comments" % wid, {"api-version": "7.1-preview.4", "$top": "50"})
        for c in cdata.get("comments", []):
            comments.append({
                "author": (c.get("createdBy") or {}).get("displayName", ""),
                "date": c.get("createdDate", ""),
                "text": html_to_text(c.get("text", "")),
            })
    except Failure:
        pass

    members = []
    team = cfg.get("team")
    if team:
        try:
            members = team_members(client, team)
        except Failure:
            pass
    assignee = person(f.get("System.AssignedTo"))
    if assignee["email"] and not any(m["email"] == assignee["email"] for m in members):
        members = [assignee] + members

    body_html = f.get(body_field) or ""
    acc_html = f.get(ACCEPTANCE) or ""
    return {
        "id": wid,
        "rev": wi.get("rev"),
        "type": wtype,
        "title": f.get("System.Title", ""),
        "state": f.get("System.State", ""),
        "category": category_of(client, wtype, f.get("System.State", ""), memo),
        "states": [s for s in states if s["category"] != "removed"] or states,
        "assignedTo": assignee,
        "members": members,
        "reason": f.get("System.Reason", ""),
        "iterationPath": f.get("System.IterationPath", ""),
        "areaPath": f.get("System.AreaPath", ""),
        "tags": f.get("System.Tags") or "",
        "priority": number(f.get(PRIORITY)),
        "hasPriority": PRIORITY in fields,
        "bodyLabel": "Repro steps" if body_field == REPRO else "Description",
        "body": html_to_text(body_html),
        "bodyRich": is_rich(body_html),
        "hasAcceptance": ACCEPTANCE in fields,
        "acceptance": html_to_text(acc_html),
        "acceptanceRich": is_rich(acc_html),
        "pointsField": points_field or "",
        "pointsLabel": {"Microsoft.VSTS.Scheduling.Effort": "Effort", "Microsoft.VSTS.Scheduling.Size": "Size"}
                       .get(points_field, "Story points"),
        "points": number(f.get(points_field)) if points_field else None,
        "hasRemaining": REMAINING in fields,
        "remaining": number(f.get(REMAINING)),
        "createdBy": person(f.get("System.CreatedBy"))["name"],
        "createdDate": f.get("System.CreatedDate", ""),
        "changedBy": person(f.get("System.ChangedBy"))["name"],
        "changedDate": f.get("System.ChangedDate", ""),
        "parent": brief(parent_id) if parent_id else None,
        "children": [brief(r) for r in related if r != parent_id],
        "comments": comments,
        "url": "%s/%s/_workitems/edit/%d" % (client.org, urllib.parse.quote(client.project), wid),
    }


def patch_ops(item, changes):
    ops = []

    def put(field, value):
        ops.append({"op": "add", "path": "/fields/" + field, "value": value})

    if "title" in changes:
        title = str(changes["title"]).strip()
        if not title:
            raise Failure("The title can't be empty")
        put("System.Title", title)
    if "state" in changes:
        put("System.State", str(changes["state"]))
    if "assignedTo" in changes:
        put("System.AssignedTo", str(changes["assignedTo"] or ""))
    if "tags" in changes:
        tags = [t.strip() for t in re.split(r"[;,]", str(changes["tags"] or "")) if t.strip()]
        put("System.Tags", "; ".join(tags))
    if "body" in changes:
        if item.get("bodyRich"):
            raise Failure("%s has images or tables; edit it in the browser" % item.get("bodyLabel", "Description"))
        put(REPRO if item.get("bodyLabel") == "Repro steps" else "System.Description", text_to_html(changes["body"]))
    if "acceptance" in changes:
        if item.get("acceptanceRich"):
            raise Failure("Acceptance criteria have images or tables; edit them in the browser")
        put(ACCEPTANCE, text_to_html(changes["acceptance"]))
    for key, field in (("points", item.get("pointsField")), ("remaining", REMAINING), ("priority", PRIORITY)):
        if key not in changes or not field:
            continue
        raw = str(changes[key]).strip()
        if raw == "":
            if item.get(key) is not None:
                ops.append({"op": "remove", "path": "/fields/" + field})
            continue
        value = number(raw)
        if value is None or value < 0:
            raise Failure("%s must be a number" % key.capitalize())
        put(field, value)
    return ops


def cmd_update(args):
    if not args:
        raise Failure("Missing work item id")
    wid = int(args[0])
    data = read_stdin_json()
    changes = data.get("changes") or {}
    cfg = load_config()
    if cfg.get("demo"):
        return demo_update(wid, changes)
    client = client_from_config(cfg)
    current = cmd_item([wid])
    if data.get("rev") is not None and current["rev"] != data["rev"]:
        raise Failure("Someone else changed this item since you opened it. Reload to see their changes.")
    ops = patch_ops(current, changes)
    if not ops:
        return {"ok": True, "item": current}
    ops.insert(0, {"op": "test", "path": "/rev", "value": current["rev"]})
    client.request("PATCH", client.url("/_apis/wit/workitems/%d" % wid), ops, "application/json-patch+json")
    return {"ok": True, "item": cmd_item([wid])}


def cmd_comment(args):
    if not args:
        raise Failure("Missing work item id")
    wid = int(args[0])
    text = str(read_stdin_json().get("text") or "").strip()
    if not text:
        raise Failure("Write a comment first")
    cfg = load_config()
    if cfg.get("demo"):
        return demo_comment(wid, text)
    client = client_from_config(cfg)
    client.request("POST", client.url("/_apis/wit/workItems/%d/comments" % wid, {"api-version": "7.1-preview.4"}),
                   {"text": text_to_html(text)})
    return {"ok": True, "item": cmd_item([wid])}


PREFS = {"hideClosed", "showBacklog"}


def cmd_pref(args):
    if len(args) != 2 or args[0] not in PREFS or args[1] not in ("on", "off"):
        raise Failure("Usage: pref hideClosed on|off")
    cfg = load_config()
    cfg[args[0]] = args[1] == "on"
    save_config(cfg)
    return {"ok": True, args[0]: cfg[args[0]]}


LAUNCHER_FILE = os.path.join(
    os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"),
    "applications", APP + ".desktop")


def cmd_launcher(args):
    # The Omarchy menu's Apps list and the app launcher are both built from
    # .desktop entries, so one here is what makes the board show up there.
    # Only rewritten when it differs, so a shell restart doesn't touch it.
    here = os.path.dirname(os.path.realpath(__file__))
    entry = "\n".join([
        "[Desktop Entry]",
        "Type=Application",
        "Name=DevOps Board",
        "Comment=Your Azure DevOps team's sprint board",
        'Exec=omarchy-shell shell summon funcoder.devops-board "{}"',
        "Icon=" + os.path.join(here, "icon.svg"),
        "Terminal=false",
        "Categories=Development;ProjectManagement;",
        "Keywords=azure;devops;sprint;scrum;board;tasks;",
        "StartupNotify=false",
        "",
    ])
    try:
        with open(LAUNCHER_FILE) as f:
            if f.read() == entry:
                return {"ok": True, "changed": False, "path": LAUNCHER_FILE}
    except OSError:
        pass
    os.makedirs(os.path.dirname(LAUNCHER_FILE), exist_ok=True)
    tmp = LAUNCHER_FILE + ".tmp"
    with open(tmp, "w") as f:
        f.write(entry)
    os.replace(tmp, LAUNCHER_FILE)
    return {"ok": True, "changed": True, "path": LAUNCHER_FILE}


def cmd_demo(args):
    cfg = load_config()
    cfg["demo"] = bool(args and args[0] == "on")
    save_config(cfg)
    if not cfg["demo"]:
        try:
            os.remove(cache_path("demo"))
        except OSError:
            pass
    return {"ok": True, "demo": cfg["demo"]}


# ---- demo data ----------------------------------------------------------------------

DEMO_ME = {"name": "Alex Morgan", "email": "alex@example.com"}
DEMO_TEAMS = [{"id": "demo", "name": "Phoenix Team", "project": "Demo"},
              {"id": "demo2", "name": "Platform Team", "project": "Demo"}]
DEMO_PEOPLE = [DEMO_ME, {"name": "Priya Shah", "email": "priya@example.com"},
               {"name": "Tom Okafor", "email": "tom@example.com"}]
DEMO_STATES = {
    "Epic": [{"name": "New", "category": "todo"}, {"name": "Active", "category": "doing"},
             {"name": "Resolved", "category": "doing"}, {"name": "Closed", "category": "done"}],
    "Feature": [{"name": "New", "category": "todo"}, {"name": "Active", "category": "doing"},
                {"name": "Resolved", "category": "doing"}, {"name": "Closed", "category": "done"}],
    "User Story": [{"name": "New", "category": "todo"}, {"name": "Active", "category": "doing"},
                   {"name": "Resolved", "category": "doing"}, {"name": "Closed", "category": "done"}],
    "Bug": [{"name": "New", "category": "todo"}, {"name": "Active", "category": "doing"},
            {"name": "Resolved", "category": "doing"}, {"name": "Closed", "category": "done"}],
    "Task": [{"name": "New", "category": "todo"}, {"name": "Active", "category": "doing"},
             {"name": "Closed", "category": "done"}],
}


def demo_seed():
    def task(i, title, state, who, rem):
        return {"id": i, "type": "Task", "title": title, "state": state, "assignedTo": who, "remaining": rem,
                "body": "", "comments": []}
    items = [
        {"id": 4700, "type": "Epic", "title": "Customer self-service portal", "state": "Active", "assignedTo": 0,
         "tags": "platform", "body": "", "acceptance": "", "comments": [], "children": []},
        {"id": 4710, "type": "Feature", "title": "Account recovery", "state": "Active", "assignedTo": 0,
         "tags": "auth", "body": "", "acceptance": "", "comments": []},
        {"id": 4812, "type": "User Story", "title": "Customers can reset their password from the sign-in page",
         "state": "Active", "assignedTo": 0, "points": 5, "tags": "auth; web",
         "body": "As a customer who forgot my password\nI want to reset it myself\nso that I don't need to call support.",
         "acceptance": "- Reset link is emailed within 1 minute\n- Link expires after 30 minutes\n- Old sessions are signed out",
         "comments": [{"author": "Priya Shah", "date": "2026-09-14T10:02:00Z", "text": "Copy for the email is in the design doc."}],
         "children": [4820, 4821, 4822, 4823]},
        {"id": 4720, "type": "Feature", "title": "Billing accuracy", "state": "Active", "assignedTo": 2,
         "tags": "billing", "body": "", "acceptance": "", "comments": []},
        {"id": 4790, "type": "Bug", "title": "Invoice PDF shows the wrong VAT total for mixed-rate orders",
         "state": "New", "assignedTo": 2, "points": 3, "tags": "billing",
         "body": "1. Create an order with standard and zero-rated lines\n2. Download the invoice\n\nVAT total includes zero-rated lines.",
         "acceptance": "", "comments": [], "children": [4791, 4792]},
        {"id": 4730, "type": "Feature", "title": "Manager reporting", "state": "Closed", "assignedTo": 1,
         "tags": "", "body": "", "acceptance": "", "comments": []},
        {"id": 4755, "type": "User Story", "title": "Export sprint report to CSV", "state": "Closed", "assignedTo": 1,
         "points": 2, "tags": "", "body": "Managers want the burndown numbers in a spreadsheet.",
         "acceptance": "", "comments": [], "children": [4756, 4757]},
        {"id": 4740, "type": "Feature", "title": "Customer portal polish", "state": "New", "assignedTo": None,
         "tags": "web; ui", "body": "", "acceptance": "", "comments": []},
        {"id": 4830, "type": "User Story", "title": "Dark mode for the customer portal", "state": "New",
         "assignedTo": None, "points": 8, "tags": "web; ui", "body": "", "acceptance": "", "comments": []},
        task(4820, "Design reset email template", "Closed", 1, 0),
        task(4821, "Token issue + expiry endpoint", "Active", 0, 4),
        task(4822, "Sign out other sessions on reset", "New", 2, 3),
        task(4823, "E2E tests for reset flow", "New", None, 5),
        task(4791, "Reproduce with fixture order", "Closed", 2, 0),
        task(4792, "Fix VAT grouping in invoice renderer", "Active", 2, 2),
        task(4756, "CSV writer", "Closed", 1, 0),
        task(4757, "Download button", "Closed", 1, 0),
    ]
    # Wire up the parent links via `children`: each Feature points at its
    # User Stories, the Epic points at all Features, and each Story points at
    # its Tasks (which are stored separately).
    by_id = {it["id"]: it for it in items}
    by_id[4700]["children"] = [4710, 4720, 4730, 4740]
    by_id[4710]["children"] = [4812]
    by_id[4720]["children"] = [4790]
    by_id[4730]["children"] = [4755]
    by_id[4740]["children"] = [4830]
    return {"items": items}


def demo_state():
    state = load_json(cache_path("demo"), None)
    if not state:
        state = demo_seed()
        save_json(cache_path("demo"), state)
    return state


def demo_find(state, wid):
    items = state["items"]
    by_id = {it["id"]: it for it in items}
    if wid not in by_id:
        raise Failure("Not found")
    it = by_id[wid]
    # Find the first item whose children reference us (its parent).
    parent = None
    for other in items:
        if wid in (other.get("children") or []):
            parent = other
            break
    return it, parent


def demo_category(wtype, state):
    return next((s["category"] for s in DEMO_STATES[wtype] if s["name"] == state), "todo")


def demo_board(iteration_id):
    its = [{"id": "s41", "name": "Sprint 41", "path": "Demo\\Sprint 41", "start": "2026-08-31T00:00:00Z",
            "finish": "2026-09-11T00:00:00Z", "timeFrame": "past"},
           {"id": "s42", "name": "Sprint 42", "path": "Demo\\Sprint 42", "start": "2026-09-14T00:00:00Z",
            "finish": "2026-09-25T00:00:00Z", "timeFrame": "current"},
           {"id": "s43", "name": "Sprint 43", "path": "Demo\\Sprint 43", "start": "2026-09-28T00:00:00Z",
            "finish": "2026-10-09T00:00:00Z", "timeFrame": "future"}]
    current = next((i for i in its if i["id"] == iteration_id), its[1])
    rows = []
    if current["id"] == "s42":
        items = demo_state()["items"]
        by_id = {it["id"]: it for it in items}

        # Roots: anything not referenced as a child elsewhere.
        referenced = {kid for it in items for kid in it.get("children", [])}
        roots = [it for it in items if it["id"] not in referenced]

        def shape(it, in_sprint):
            who = DEMO_PEOPLE[it["assignedTo"]] if it["assignedTo"] is not None else {"name": "", "email": ""}
            kids = [shape(by_id[kid], in_sprint) for kid in it.get("children", [])
                    if kid in by_id and by_id[kid]["type"] != "Task"]
            tasks = [task_shape(by_id[t], in_sprint) for t in it.get("children", [])
                     if t in by_id and by_id[t]["type"] == "Task"]
            return {"id": it["id"], "type": it["type"], "title": it["title"], "state": it["state"],
                    "category": demo_category(it["type"], it["state"]), "assignedTo": who["name"],
                    "assignedEmail": who["email"], "points": it.get("points"),
                    "remaining": None,
                    "tags": [t.strip() for t in (it.get("tags") or "").split(";") if t.strip()],
                    "inSprint": in_sprint, "children": kids, "tasks": tasks}

        def task_shape(t, in_sprint):
            tw = DEMO_PEOPLE[t["assignedTo"]] if t["assignedTo"] is not None else {"name": "", "email": ""}
            return {"id": t["id"], "type": "Task", "title": t["title"], "state": t["state"],
                    "category": demo_category("Task", t["state"]), "assignedTo": tw["name"],
                    "assignedEmail": tw["email"], "points": None, "remaining": t.get("remaining"),
                    "tags": [], "inSprint": in_sprint, "children": [], "tasks": []}

        rows = [shape(r, True) for r in roots]
    return {"org": "https://dev.azure.com/demo", "project": "Demo", "team": DEMO_TEAMS[0], "user": DEMO_ME,
            "iteration": current, "iterations": its, "rows": rows, "demo": True,
            "fetchedAt": time.strftime("%Y-%m-%dT%H:%M:%S%z")}


def demo_item(wid):
    state = demo_state()
    it, parent = demo_find(state, wid)
    by_id = {x["id"]: x for x in state["items"]}
    who = DEMO_PEOPLE[it["assignedTo"]] if it["assignedTo"] is not None else {"name": "", "email": ""}
    is_task = it["type"] == "Task"

    def brief(x):
        xw = DEMO_PEOPLE[x["assignedTo"]] if x["assignedTo"] is not None else {"name": ""}
        return {"id": x["id"], "type": x["type"], "title": x["title"], "state": x["state"],
                "category": demo_category(x["type"], x["state"]), "assignedTo": xw["name"],
                "remaining": x.get("remaining")}

    return {
        "id": wid, "rev": state.get("rev", 1), "type": it["type"], "title": it["title"], "state": it["state"],
        "category": demo_category(it["type"], it["state"]), "states": DEMO_STATES[it["type"]],
        "assignedTo": who, "members": DEMO_PEOPLE, "reason": "", "iterationPath": "Demo\\Sprint 42",
        "areaPath": "Demo\\Web", "tags": it.get("tags", ""), "priority": 2, "hasPriority": True,
        "bodyLabel": "Repro steps" if it["type"] == "Bug" else "Description", "body": it.get("body", ""),
        "bodyRich": False, "hasAcceptance": not is_task and it["type"] != "Bug",
        "acceptance": it.get("acceptance", ""), "acceptanceRich": False,
        "pointsField": "" if is_task else "Microsoft.VSTS.Scheduling.StoryPoints", "pointsLabel": "Story points",
        "points": it.get("points"), "hasRemaining": is_task, "remaining": it.get("remaining"),
        "createdBy": "Priya Shah", "createdDate": "2026-09-01T09:00:00Z", "changedBy": DEMO_ME["name"],
        "changedDate": "2026-09-15T16:30:00Z", "parent": brief(parent) if parent else None,
        "children": [brief(by_id[c]) for c in (it.get("children") or []) if c in by_id],
        "comments": it.get("comments", []),
        "url": "https://dev.azure.com/demo/Demo/_workitems/edit/%d" % wid,
    }


def demo_update(wid, changes):
    state = demo_state()
    it, _ = demo_find(state, wid)
    for key in ("title", "state", "tags", "body", "acceptance"):
        if key in changes:
            it[key] = changes[key]
    for key in ("points", "remaining"):
        if key in changes:
            it[key] = number(changes[key])
    if "assignedTo" in changes:
        it["assignedTo"] = next((i for i, p in enumerate(DEMO_PEOPLE) if p["email"] == changes["assignedTo"]), None)
    state["rev"] = state.get("rev", 1) + 1
    save_json(cache_path("demo"), state)
    return {"ok": True, "item": demo_item(wid)}


def demo_comment(wid, text):
    state = demo_state()
    it, _ = demo_find(state, wid)
    it.setdefault("comments", []).insert(0, {"author": DEMO_ME["name"], "date": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "text": text})
    save_json(cache_path("demo"), state)
    return {"ok": True, "item": demo_item(wid)}


COMMANDS = {
    "status": cmd_status,
    "connect": cmd_connect,
    "disconnect": cmd_disconnect,
    "teams": cmd_teams,
    "set-team": cmd_set_team,
    "board": cmd_board,
    "item": cmd_item,
    "update": cmd_update,
    "comment": cmd_comment,
    "demo": cmd_demo,
    "pref": cmd_pref,
    "launcher": cmd_launcher,
}


def main(argv):
    if not argv or argv[0] not in COMMANDS:
        sys.stderr.write(__doc__)
        return 2
    try:
        emit(COMMANDS[argv[0]](argv[1:]))
    except Failure as exc:
        emit({"error": str(exc)})
    except Exception as exc:  # keep the board informative instead of silent
        emit({"error": "%s: %s" % (type(exc).__name__, exc)})
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
