"""OpenTodo's shared test vectors, read from the pinned clone. See spec/README.md."""

import json
import os
import pathlib
import unittest

# A clone beside this repo, unless OPENTODO_SRC says otherwise.
OPENTODO = pathlib.Path(os.environ.get("OPENTODO_SRC", pathlib.Path(__file__).resolve().parents[3] / "opentodo"))
LIB = OPENTODO / "web/src/lib"


def read(relative):
    """A file's text from the clone, or skip the test when the clone is missing."""
    path = OPENTODO / relative
    if not path.exists():
        raise unittest.SkipTest(f"no {path}")
    return path.read_text()


def load(name):
    """A parsed vectors file from web/src/lib."""
    return json.loads(read(f"web/src/lib/{name}.vectors.json"))
