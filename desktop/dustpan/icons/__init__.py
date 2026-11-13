"""Project icons: all of Lucide 1.48.0 (spec/icons.md). No GTK here.

paths.json and lucide.json are built from Lucide's downloads by sync.py. catalogue.json is OpenTodo's file,
copied unchanged: the 411 icons its server and web app know. Every icon here can be stored through sync;
the web app shows a project's dot for one outside its catalogue. The icons are Lucide's (ISC, see
LICENSE-lucide.txt).
"""

import json
import pathlib
import re

HERE = pathlib.Path(__file__).parent
PATHS = json.loads((HERE / "paths.json").read_text())
LUCIDE = json.loads((HERE / "lucide.json").read_text())
ALIASES = LUCIDE["aliases"]  # Lucide's old names, still drawn: a stored name stays good
CATALOGUE = json.loads((HERE / "catalogue.json").read_text())
SERVER = {e["name"] for e in CATALOGUE}  # the names OpenTodo's REST, MCP and web app know

# The picker's categories, in order: (id, label, Lucide's categories, the icon beside the label).
# OpenTodo's 411 icons keep OpenTodo's categories (OPENTODO maps them): they're chosen with care.
# Lucide files the rest in 42 categories, most icons in several, and not always well. Each of those
# goes to the first group in PRIORITY it belongs to, the most specific first. Its people icons sit in
# Lucide's broad "account" category, so an account icon named for a user goes to People.
GROUPS = (
    ("work", "Work", (), "briefcase"),
    ("home", "Home", ("home", "buildings"), "house"),
    ("people", "People", ("people", "emoji"), "user"),
    ("learning", "Learning", (), "graduation-cap"),
    ("food", "Food and drink", ("food-beverage",), "utensils"),
    ("travel", "Travel", ("travel",), "plane"),
    ("transport", "Transport", ("transportation",), "car"),
    ("nature", "Nature", ("nature", "sustainability"), "leaf"),
    ("animals", "Animals", ("animals",), "paw-print"),
    ("weather", "Weather", ("weather", "seasons"), "cloud-sun"),
    ("health", "Health", ("medical", "accessibility"), "heart-pulse"),
    ("leisure", "Leisure and sport", ("sports", "gaming"), "trophy"),
    ("money", "Money", ("finance",), "wallet"),
    ("shopping", "Shopping", ("shopping",), "shopping-cart"),
    ("tools", "Tools", ("tools",), "wrench"),
    ("science", "Science", ("science",), "flask-conical"),
    ("time", "Time", ("time",), "clock"),
    ("communication", "Communication", ("communication", "mail", "notifications", "social"), "message-circle"),
    ("media", "Media", ("multimedia", "photography"), "camera"),
    ("devices", "Devices", ("devices", "connectivity"), "laptop"),
    ("files", "Files", ("files",), "file"),
    ("security", "Security", ("security",), "lock"),
    ("charts", "Charts and maths", ("charts", "math"), "chart-column"),
    ("design", "Design", ("design",), "palette"),
    ("shapes", "Shapes and symbols", ("shapes",), "shapes"),
    ("text", "Text", ("text",), "type"),
    ("layout", "Layout", ("layout",), "layout-grid"),
    ("development", "Development", ("development",), "code"),
    ("account", "Accounts and settings", ("account",), "settings"),
    ("arrows", "Arrows and navigation", ("arrows", "navigation", "cursors"), "arrow-right"),
)
PRIORITY = ("animals", "food", "weather", "nature", "transport", "travel", "home", "shopping", "money",
            "health", "leisure", "science", "time", "tools", "security", "people", "media", "communication",
            "devices", "files", "charts", "shapes", "design", "text", "layout", "development", "account", "arrows")
OPENTODO = {"work": "work", "home": "home", "people": "people", "travel": "travel", "food": "food",
            "health": "health", "money": "money", "learning": "learning", "nature": "nature", "animals": "animals",
            "tools": "tools", "tech": "devices", "time": "time", "communication": "communication",
            "symbols": "shapes", "leisure": "leisure"}
CATEGORIES = tuple((group, label) for group, label, _c, _i in GROUPS)
LABELS = dict(CATEGORIES)
SYMBOLS = {group: icon for group, _l, _c, icon in GROUPS}
MEMBERS = {group: set(members) for group, _l, members, _i in GROUPS}


def group_of(name, categories):
    """The group for one of Lucide's icons outside OpenTodo's catalogue."""
    if "account" in categories and "user" in name.split("-"):
        return "people"
    return next(group for group in PRIORITY if MEMBERS[group] & set(categories))


def entries():
    """One entry per icon: its name, group, keywords, Lucide's categories, and whether OpenTodo knows it.

    In picker order: by group; in each, OpenTodo's icons first, in its order, then the rest by name.
    An icon OpenTodo knows by an old name keeps that name, so the web app can draw it.
    """
    old = {ALIASES[name]: name for name in SERVER if name in ALIASES}
    words = {e["name"]: e["keywords"] for e in CATALOGUE}
    curated = {e["name"]: OPENTODO[e["category"]] for e in CATALOGUE}
    place = {e["name"]: i for i, e in enumerate(CATALOGUE)}
    order = {group: i for i, (group, *_rest) in enumerate(GROUPS)}
    found = []
    for lucide_name, info in LUCIDE["icons"].items():
        name = old.get(lucide_name, lucide_name)
        found.append({"name": name, "category": curated.get(name) or group_of(lucide_name, info["categories"]), "categories": info["categories"],
                      "keywords": list(dict.fromkeys([*words.get(name, []), *info["tags"]])),
                      "server": name in SERVER})
    found.sort(key=lambda e: (order[e["category"]], not e["server"], place.get(e["name"], 0), e["name"]))
    return found


ENTRIES = entries()


def known(name):
    """True for a name this client can draw. A newer client may have stored one it can't."""
    return isinstance(name, str) and (name in PATHS or name in ALIASES)


def path(name):
    return PATHS[ALIASES.get(name, name)]


def title(name):
    """An icon's readable name: "paw-print" is "paw print"."""
    return name.replace("-", " ")


def rank(entry, query):
    """OpenTodo's match order: 0 exact name, 1 name prefix, 2 in the name, 3 keyword, 4 category; -1 none."""
    q = query.strip().lower()
    name = entry["name"]
    if not q or name == q:
        return 0
    if name.startswith(q):
        return 1
    if q in name:
        return 2
    if any(q in k.lower() for k in entry["keywords"]):
        return 3
    if any(q in c for c in (entry["category"], LABELS[entry["category"]].lower(), *entry["categories"])):
        return 4
    return -1


def search(query):
    """The entries matching query, best first; in a tie OpenTodo's icons first, then picker order."""
    hits = sorted((r, not e["server"], i) for i, e in enumerate(ENTRIES) if (r := rank(e, query)) >= 0)
    return [ENTRIES[i] for _r, _s, i in hits]


def suggest(project_name, limit=8):
    """Icons for a project's name, best first. Whole words only, so "Car" doesn't offer the carrot.

    A word matches an icon's name (0), a word of its name (1), a keyword's word (2) or its category (3).
    A plural also tries its singular. In a tie, OpenTodo's icons come first: they're the everyday ones.
    """
    words = {w for w in re.findall(r"[a-z0-9]+", project_name.lower()) if len(w) > 2}
    words |= {w[:-1] for w in words if w.endswith("s") and len(w) > 3}
    if not words:
        return []

    def score(entry):
        keywords = {w for k in entry["keywords"] for w in re.findall(r"[a-z0-9]+", k.lower())}
        category = {entry["category"], LABELS[entry["category"]].lower(), *entry["categories"]}
        return min((0 if entry["name"] == w else 1 if w in entry["name"].split("-") else
                    2 if w in keywords else 3 if w in category else 4) for w in words)

    hits = sorted((s, not e["server"], i) for i, e in enumerate(ENTRIES) if (s := score(e)) < 4)
    return [ENTRIES[i]["name"] for _s, _k, i in hits[:limit]]


def svg(name, color, size):
    """The icon as SVG bytes, size pixels square, its lines in color. 1.5 px lines: lighter than Lucide's 2."""
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 24 24" '
            f'fill="none" stroke="{color}" stroke-width="1.5" stroke-linecap="round" '
            f'stroke-linejoin="round">{path(name)}</svg>').encode()
