"""Read one quick-add line. Port of internal/quickadd/parse.go.

Spans are (start, end) character ranges of the line. A recognised span leaves the title.
"""

from dataclasses import dataclass, field

from .. import sectors
from ..recurrence import first_occurrence
from .attributes import match_duration, match_energy, match_label, match_priority, match_project, match_spent
from .dates import (DateCtx, match_date_at, match_deadline_at, match_time_at, ordinal_out_of_range_at,
                    sector_phrase_at)
from .reminders import match_reminder_at
from .repeats import RepeatMatch, match_repeat_at
from .words import VOCABS, active_languages, strip_spans, tokenize, words_at

# Dustpan differs here (spec/quickadd.md): English day names that are also everyday words.
WORD_LIKE_DAYS = {"sun", "sat", "wed"}
ARTICLES = {"the", "a", "an", "my", "our", "your", "his", "her", "their"}


@dataclass
class Context:
    today: str  # YYYY-MM-DD
    now: str  # HH:MM
    languages: list = field(default_factory=lambda: ["en"])
    projects: list = field(default_factory=list)  # dicts: id, name, parent_id, archived, deleted
    day_month_order: str = ""  # "DM" or "MD"; the first language's when empty
    week_start: int = 1  # 0 = Sunday
    day_parts: bool = False  # read "this morning", "tomorrow afternoon"
    energy: bool = False  # read ~deep, ~low
    sectors: bool = False  # read "this week", "sometime next month"


@dataclass
class Result:
    title: str
    due: dict | None = None  # {"date"} or {"date", "time"}
    deadline: str | None = None
    someday: bool = False
    sector: str | None = None  # "2026-W45": from a sector phrase on a line without a date
    evening: bool = False
    day_part: str | None = None  # "morning" or "afternoon"
    project_id: str | None = None
    labels: list = field(default_factory=list)  # names, as typed
    priority: int | None = None
    energy: str | None = None
    estimate_minutes: int | None = None
    spent_minutes: int | None = None
    recurrence: str | None = None
    reminders: list = field(default_factory=list)  # as typed; see reminders.resolve


def parse(line, ctx):
    """What a line sets. Pure: the result depends only on the line and ctx."""
    return Parser(line, ctx).run()


class Parser:
    def __init__(self, line, ctx):
        self.line = line
        self.ctx = ctx
        vocabs = [VOCABS[code] for code in active_languages(ctx.languages)]
        self.dctx = DateCtx(ctx.today, ctx.now, vocabs, ctx.day_month_order or vocabs[0]["dayMonthOrder"],
                            ctx.week_start)
        self.bare_hour_is_time = any(v["hourSuffixH"] for v in vocabs)
        self.tokens, self.quotes = tokenize(line)
        # What was recognised: (value, span), or None.
        self.date = self.time = self.deadline = self.project = self.repeat = self.day_part = self.sector = None
        self.priority = self.estimate = None
        self.date_bare = False  # a month name alone, which a later complete date replaces
        self.repeat_first = ""  # the first date of "every other friday"
        self.time_date = ""  # the day a time like "in 20 hours" lands on
        self.spent = None
        self.evening = self.someday = None  # spans
        self.labels, self.energies, self.reminders = [], [], []

    def span(self, start, to):
        return self.tokens[start].start, self.tokens[to - 1].end

    def run(self):
        i = 0
        while i < len(self.tokens):
            if self.tokens[i].quoted:
                i += 1
            else:
                i = self.attribute(i) or self.phrase(i)
        return self.result()

    def words(self, i, key):
        return words_at(self.tokens, i, self.dctx.vocabs, lambda v: v[key])

    def set_date_today(self, span):
        """A part of the day without a date means today, and replaces a month name alone."""
        if self.date is None or self.date_bare:
            self.date, self.date_bare = (self.ctx.today, span), False

    # ---- single tokens and fixed words ----

    def attribute(self, i):
        """The next token index after an attribute at i, or 0."""
        tokens, text = self.tokens, self.tokens[i].text
        one = self.span(i, i + 1)
        if self.project is None and len(text) > 1 and text[0] == "#":
            if project := match_project(text, self.ctx.projects):
                self.project = project["id"], one
                return i + 1
        if label := match_label(text):
            self.labels.append((label, one))
            return i + 1
        if self.ctx.energy and (energy := match_energy(text)):
            self.energies.append((energy, one))
            return i + 1
        if self.priority is None and (priority := match_priority(text)):
            self.priority = priority, one
            return i + 1
        if self.estimate is None:
            if spent := match_spent(text):
                self.spent, self.estimate = spent[0], (spent[1], one)
                return i + 1
            if minutes := match_duration(text, self.bare_hour_is_time):
                self.estimate = minutes, one
                return i + 1
        if self.deadline is None and (dl := match_deadline_at(tokens, i, self.dctx)):
            self.deadline = dl.date, self.span(dl.start, dl.to)
            # A time after the deadline is read past, and stays in the title.
            tm = match_time_at(tokens, dl.to, self.dctx)
            return tm.to if tm else dl.to
        if nxt := self.this_part(i):
            return nxt
        if self.evening is None and (n := self.words(i, "eveningWords")):
            self.evening = self.span(i, i + n)
            self.set_date_today(self.evening)
            return i + n
        return 0

    def part_free(self):
        """A line sets one part of the day: the evening flag or a day part, never both."""
        return self.evening is None and self.day_part is None

    def this_part(self, i):
        """ "this morning", "this afternoon": today, with that part."""
        if not self.ctx.day_parts or not self.part_free():
            return 0
        for part in ("morning", "afternoon"):
            if n := self.words(i, f"{part}Words"):
                self.day_part = part, self.span(i, i + n)
                self.set_date_today(self.day_part[1])
                return i + n
        return 0

    def part_after(self, to):
        """A part word right after a date ("tomorrow morning"). Returns where reading goes on."""
        if not self.ctx.day_parts or not self.part_free() or to >= len(self.tokens) or self.tokens[to].quoted:
            return to
        best, part = 0, ""
        for name in ("morning", "afternoon", "evening"):
            n = words_at(self.tokens, to, self.dctx.vocabs, lambda v: v["partWords"][name])
            if n > best:
                best, part = n, name
        if not best:
            return to
        span = self.span(to, to + best)
        if part == "evening":
            self.evening = span
        else:
            self.day_part = part, span
        return to + best

    # ---- phrases ----

    def phrase(self, i):
        """The longest of a date, a time, a repeat rule or a reminder at i, then the someday words."""
        tokens, dctx = self.tokens, self.dctx
        dm = tm = None
        if self.date is None or self.date_bare:
            dm = match_date_at(tokens, i, dctx)
            if self.date is not None and dm and dm.bare:  # after a bare month, only a complete date
                dm = None
            if dm and self.word_like_day(dm, i):
                dm = None
        if self.time is None:
            tm = match_time_at(tokens, i, dctx)
        # After the first rule only a literal match counts. "5th Friday" is one too.
        rm = match_repeat_at(tokens, i, dctx)
        if rm and self.repeat is not None and not rm.literal:
            rm = None
        if rm is None and (n := ordinal_out_of_range_at(tokens, i, dctx)):
            rm = RepeatMatch("", i, i + n, literal=True)
        mm = match_reminder_at(tokens, i, dctx)

        phrase_end = max(rm.to if rm else 0, mm[2] if mm else 0)
        if phrase_end > max(dm.to if dm else 0, tm.to if tm else 0):
            if rm and rm.to == phrase_end:
                if not rm.literal:
                    self.repeat = rm.rule, self.span(rm.start, rm.to)
                    self.repeat_first = rm.first
                return rm.to
            self.reminders.append((mm[0], self.span(mm[1], mm[2])))
            return mm[2]
        if dm and (tm is None or dm.to >= tm.to):
            self.date, self.date_bare = (dm.date, self.span(dm.start, dm.to)), dm.bare
            return self.part_after(dm.to)
        if tm:
            self.time, self.time_date = (tm.time, self.span(tm.start, tm.to)), tm.date
            return tm.to
        # A sector phrase, like the someday words, counts only on a line without a date.
        if self.ctx.sectors and self.sector is None:
            n, word = sector_phrase_at(tokens, i, dctx)
            if n:
                self.sector = sectors.resolve(word, self.ctx.today, dctx.week_start), self.span(i, i + n)
                return i + n
        if self.someday is None and (n := self.words(i, "somedayWords")):
            self.someday = self.span(i, i + n)
            return i + n
        return i + 1

    def word_like_day(self, dm, i):
        """A bare "sun", "sat" or "wed" read as text: after "the", "a", "my"…, or mid-sentence,
        unless a time or a tag follows, or it ends the line."""
        tokens = self.tokens
        if dm.to != i + 1 or tokens[i].norm not in WORD_LIKE_DAYS:
            return False
        if i > 0 and tokens[i - 1].norm in ARTICLES:
            return True
        if i + 1 == len(tokens) or not tokens[i + 1].quoted and self.is_attribute(tokens[i + 1].text):
            return False
        return match_time_at(tokens, i + 1, self.dctx) is None

    def is_attribute(self, text):
        """Whether attribute() reads this token as a tag, whatever the line has already set."""
        return bool(len(text) > 1 and text[0] == "#" and match_project(text, self.ctx.projects)
                    or match_label(text) or self.ctx.energy and match_energy(text) or match_priority(text)
                    or match_spent(text) or match_duration(text, self.bare_hour_is_time))

    # ---- result ----

    def due(self):
        """The date, else the rule's first date, the time's own date, or today."""
        if self.date is None and self.time is None and self.repeat is None:
            return None
        if self.date:
            day = self.date[0]
        elif self.repeat:
            day = self.repeat_first or first_occurrence(self.repeat[0], self.ctx.today)
        else:
            day = self.time_date or self.ctx.today
        return {"date": day, "time": self.time[0]} if self.time else {"date": day}

    def result(self):
        sectored = self.sector is not None and not (self.date or self.time or self.repeat)
        parked = self.someday is not None and not (sectored or self.date or self.time or self.deadline or self.repeat)
        found = [self.date, self.time, self.day_part, self.deadline, self.project, self.repeat, self.priority,
                 self.estimate, *self.energies, *self.labels, *self.reminders]
        remove = [f[1] for f in found if f] + [s for s in (self.evening, self.someday if parked else None,
                                              self.sector[1] if sectored else None) if s]
        return Result(
            title=strip_spans(self.line, remove, self.quotes),
            due=self.due(),
            deadline=self.deadline and self.deadline[0],
            someday=parked,
            sector=self.sector[0] if sectored else None,
            evening=self.evening is not None,
            day_part=self.day_part and self.day_part[0],
            project_id=self.project and self.project[0],
            labels=[label for label, _ in self.labels],
            priority=self.priority and self.priority[0],
            energy=self.energies[-1][0] if self.energies else None,
            estimate_minutes=self.estimate and self.estimate[0],
            spent_minutes=self.spent,
            recurrence=self.repeat and self.repeat[0],
            reminders=[reminder for reminder, _ in self.reminders],
        )
