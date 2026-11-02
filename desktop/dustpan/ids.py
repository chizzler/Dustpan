"""Deterministic ids. Devices that derive an id from the same inputs write the same entity.

Mirrors ids.NameID (Go) and web/src/lib/ids.ts: the first 16 bytes of
SHA-256(ns + ":" + name), formatted as a version 8 UUID.
"""

import hashlib
import uuid


def name_id(ns, name):
    b = bytearray(hashlib.sha256(f"{ns}:{name}".encode()).digest()[:16])
    b[6] = (b[6] & 0x0F) | 0x80
    b[8] = (b[8] & 0x3F) | 0x80
    return str(uuid.UUID(bytes=bytes(b)))


def occurrence_id(series_id, day):
    """The completed occurrence record of a series on one date."""
    return name_id("occurrence", f"{series_id}:{day}")


def detached_id(series_id, day):
    """The "this occurrence only" copy of a series on one date."""
    return name_id("occurrence", f"{series_id}:detach:{day}")


def default_reminder_id(user_id, task_id):
    """A person's default reminder on a task."""
    return name_id("default-reminder", f"{user_id}\0{task_id}")
