"""Manual order: the positions a move writes. Port of planMove in web/src/lib/ordering.ts.

Lists sort by (position, id). A move usually writes one position: the midpoint between its
new neighbours. When no distinct number fits there, the smallest window of neighbours
around the gap is spread evenly with the moved item.
"""

GAP = 1000


def spread(lower, upper, n, anchor):
    """n increasing positions strictly between lower and upper (None is open), or None when they don't fit."""
    if lower is None and upper is None:
        return [anchor + i * GAP for i in range(n)]
    if lower is None:
        return [upper - (n - i) * GAP for i in range(n)]
    if upper is None:
        return [lower + (i + 1) * GAP for i in range(n)]
    if not upper > lower:
        return None
    step = (upper - lower) / (n + 1)
    # A window of several must leave room for about ten more bisections.
    if n > 1 and step < max(abs(lower), abs(upper), 1) * 2 ** -42:
        return None
    out, prev = [], lower
    for i in range(1, n + 1):
        p = lower + step * i
        if not prev < p < upper:
            return None
        out.append(p)
        prev = p
    return out


def plan_move(siblings, moved_id, index, fallback):
    """The (id, position) writes that put moved_id at index of its target list.

    siblings: (id, position) pairs of the target list; the moved item may be among them.
    index counts the list without the moved item. Returns [] when nothing moves.
    """
    ordered = sorted(siblings, key=lambda s: (s[1], s[0]))
    start = next((i for i, s in enumerate(ordered) if s[0] == moved_id), None)
    items = [s for s in ordered if s[0] != moved_id]
    k = max(0, min(len(items), index))
    if start == k:
        return []
    if not items:
        return [(moved_id, fallback)]
    left, right = k, k - 1  # items[left..right] is spread along with the moved item
    while True:
        lower = items[left - 1][1] if left > 0 else None
        upper = items[right + 1][1] if right < len(items) - 1 else None
        points = spread(lower, upper, right - left + 2, items[0][1])
        if points:
            window = items[left:k] + [(moved_id, None)] + items[k:right + 1]
            changes = [(item_id, p) for (item_id, old), p in zip(window, points) if item_id == moved_id or old != p]
            return sorted(changes, key=lambda c: c[0] != moved_id)  # the moved item first
        # Grow towards the side with fewer window items.
        if left > 0 and (right >= len(items) - 1 or k - left <= right - k + 1):
            left -= 1
        else:
            right += 1
