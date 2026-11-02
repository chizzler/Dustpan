"""Labels without GTK: finding them as you type, the picker's order, duplicates and the chips a row shows.

See spec/labels.md. Writes are in writes.py.
"""

import re
import unicodedata

from .model import order_key

MAX_RECENT = 8  # labels remembered as recently assigned on this device
ROW_CHIPS = 2  # a task row shows this many labels, then "+n"


def fold(text):
    """For matching: no case, no accents."""
    decomposed = unicodedata.normalize("NFKD", text if isinstance(text, str) else "")
    return "".join(c for c in decomposed if not unicodedata.combining(c)).casefold().strip()


def key(name):
    """Two labels with the same key have the same name, as far as the user can tell."""
    return (name if isinstance(name, str) else "").strip().lower()


def in_order(labels):
    """Live labels in sidebar order: position, then id."""
    return sorted(labels, key=order_key)


def rank(name, query):
    """How well name matches a folded query: 0 best, None for no match."""
    name = fold(name)
    if name.startswith(query):
        return 0
    if any(word.startswith(query) for word in re.split(r"[^\w]+", name) if word):
        return 1
    if query in name:
        return 2
    letters = iter(name)
    return 3 if all(c in letters for c in query) else None  # the letters in order, with gaps


def find(labels, query):
    """The labels matching what's typed, best first. Ties keep the given order."""
    query = fold(query)
    if not query:
        return list(labels)
    ranked = [(r, i, label) for i, label in enumerate(labels) if (r := rank(label.get("name", ""), query)) is not None]
    return [label for _, _, label in sorted(ranked, key=lambda item: item[:2])]


def picker_order(labels, recent):
    """Recently assigned on this device first, newest first, then the rest in sidebar order."""
    by_id = {label.id: label for label in labels}
    first = [by_id[i] for i in dict.fromkeys(recent) if i in by_id]
    seen = {label.id for label in first}
    return first + [label for label in in_order(labels) if label.id not in seen]


def remember(recent, label_ids):
    """The recent list after assigning label_ids."""
    return list(dict.fromkeys([*reversed(label_ids), *recent]))[:MAX_RECENT]


def exact(labels, name):
    """The label named name, ignoring case, or None. With duplicates, the first in sidebar order."""
    wanted = key(name)
    return next((label for label in in_order(labels) if key(label.get("name")) == wanted), None) if wanted else None


def duplicates(labels):
    """Ids of labels whose name another label shares."""
    by_key = {}
    for label in labels:
        by_key.setdefault(key(label.get("name")), []).append(label.id)
    return {i for ids in by_key.values() if len(ids) > 1 for i in ids}


def shown(ids, labels_by_id, skip=None):
    """The labels a task shows, in its own order: known and live, once each. skip: the label page we're on."""
    out, seen = [], set()
    for label_id in ids or []:
        label = labels_by_id.get(label_id)
        if label is not None and label_id != skip and label_id not in seen:
            seen.add(label_id)
            out.append(label)
    return out


def carrying(tasks, label_id):
    """Live tasks with the label: what deleting or merging it rewrites."""
    return [t for t in tasks if t.get("deleted_at") is None and label_id in (t.get("labels") or [])]
