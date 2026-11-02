"""Quick add: read "Call Sam tomorrow at 3pm #Work @phone p1 every week" into task fields.

A port of OpenTodo's internal/quickadd (v0.18.0), in six languages, checked against
web/src/lib/nlp/quickadd.vectors.json. See spec/quickadd.md.
"""

from .parse import Context, Result, parse
from .reminders import resolve
from .words import active_languages

__all__ = ["Context", "Result", "active_languages", "parse", "resolve"]
