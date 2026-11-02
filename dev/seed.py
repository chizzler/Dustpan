#!/usr/bin/env python3
"""Fill the local dev server with sample data through the REST API.

Covers the must-haves: nested projects, sections, subtasks, labels,
priorities, due dates (floating and zoned) and recurrence.
Run it once against an empty server. Reads dev/credentials.
"""

import json
import pathlib
import urllib.request

DEV = pathlib.Path(__file__).resolve().parent


def load_credentials():
    creds = {}
    for line in (DEV / "credentials").read_text().splitlines():
        key, _, value = line.partition("=")
        creds[key] = value
    return creds


CREDS = load_credentials()


def post(path, body):
    req = urllib.request.Request(
        CREDS["OPENTODO_URL"] + "/api/v1/" + path,
        data=json.dumps(body).encode(),
        method="POST",
        headers={
            "Authorization": "Bearer " + CREDS["OPENTODO_TOKEN"],
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req) as resp:
        return json.load(resp)


def project(name, parent=None, color="#3b82f6"):
    return post("projects", {"name": name, "parent_id": parent, "color": color})["id"]


def section(name, project_id):
    return post("sections", {"name": name, "project_id": project_id})["id"]


def label(name, color="#22c55e"):
    return post("labels", {"name": name, "color": color})["id"]


def task(title, **fields):
    return post("tasks", {"title": title, **fields})["id"]


def main():
    errand = label("errand", "#f97316")
    phone = label("phone", "#8b5cf6")

    # Inbox: no project.
    task("Book dentist", labels=[phone], priority=2, due={"date": "2026-11-03"})
    task("Read OpenTodo sync spec", priority=1)

    # Nested projects, three levels deep.
    home = project("Home", color="#22c55e")
    garden = project("Garden", parent=home, color="#65a30d")
    veggies = project("Veggie patch", parent=garden, color="#84cc16")

    task("Water plants", project_id=garden, recurrence="every 3 days after completion",
         due={"date": "2026-11-01"})
    task("Plant tomatoes", project_id=veggies, priority=2, due={"date": "2026-11-08"})
    task("Pay electricity bill", project_id=home, priority=1,
         recurrence="every month", due={"date": "2026-11-15"})
    task("Buy light bulbs", project_id=home, labels=[errand])

    # Sections, with nested subtasks.
    work = project("Work", color="#ef4444")
    doing = section("Doing", work)
    next_up = section("Next", work)
    section("Waiting", work)

    release = task("Ship release 1.2", project_id=work, section_id=doing, priority=1,
                   due={"date": "2026-11-04", "time": "16:00", "tz": "Australia/Sydney"})
    notes = task("Write release notes", project_id=work, section_id=doing, parent_id=release)
    task("Collect changelog entries", project_id=work, section_id=doing, parent_id=notes)
    task("Tag the build", project_id=work, section_id=doing, parent_id=release)
    task("Call supplier", project_id=work, section_id=next_up, labels=[phone], priority=3,
         estimate_minutes=15)
    task("Plan Q1 roadmap", project_id=work, estimate_minutes=120)

    print("Seeded projects, sections, labels and tasks.")


if __name__ == "__main__":
    main()
