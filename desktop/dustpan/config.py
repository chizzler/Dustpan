"""Where the client keeps its settings and data (XDG base directories).

 Dustpan runs standalone without a config file. When OpenTodo sync is enabled,
the config file holds KEY=VALUE lines: OPENTODO_URL and OPENTODO_TOKEN.
The URL must be https, except on this machine: the token travels in every request.
DUSTPAN_CONFIG and DUSTPAN_DATA override the paths, for development.
"""

import ipaddress
import os
import pathlib
import tempfile
import urllib.parse
from dataclasses import dataclass

APP_ID = "io.github.chizzler.Dustpan"
KEYS = ("OPENTODO_URL", "OPENTODO_TOKEN")


def _xdg(var, fallback):
    return pathlib.Path(os.environ.get(var) or pathlib.Path.home() / fallback)


def config_path():
    if path := os.environ.get("DUSTPAN_CONFIG"):
        return pathlib.Path(path)
    return _xdg("XDG_CONFIG_HOME", ".config") / "dustpan" / "config"


def data_dir():
    if path := os.environ.get("DUSTPAN_DATA"):
        return pathlib.Path(path)
    return _xdg("XDG_DATA_HOME", ".local/share") / "dustpan"


@dataclass
class Config:
    url: str
    token: str


class ConfigMissing(Exception):
    pass


def _parse(text):
    values = {}
    for line in text.splitlines():
        key, sep, value = line.partition("=")
        if sep and not key.lstrip().startswith("#"):
            values[key.strip()] = value.strip()
    return values


def validate(url, token, source=None):
    """Validate a server URL and API token, returning Config or raising ConfigMissing."""
    prefix = f"{source}: " if source else ""
    url = (url or "").strip()
    token = (token or "").strip()
    if any(c in url or c in token for c in ("\n", "\r")):
        raise ConfigMissing(f"{prefix}URL and token must be single-line values")
    if not url or not token:
        raise ConfigMissing(f"{source} needs OPENTODO_URL and OPENTODO_TOKEN" if source
                            else "Enter both the server URL and API token")
    if not safe_url(url):
        raise ConfigMissing(f"{prefix}OPENTODO_URL must start with https:// (http only for localhost)")
    return Config(url, token)


def load():
    path = config_path()
    try:
        text = path.read_text()
    except FileNotFoundError:
        raise ConfigMissing(f"no config at {path}") from None
    except OSError as err:
        raise ConfigMissing(f"{path}: {err}") from None
    values = _parse(text)
    return validate(values.get("OPENTODO_URL", ""), values.get("OPENTODO_TOKEN", ""), source=path)


def load_optional():
    """Return (Config or None, warning or None).

    A missing file or blank credentials mean standalone local mode (None, None).
    A malformed file also starts in standalone mode, returning the error text so
    the user can fix it without being locked out of their tasks.
    """
    path = config_path()
    try:
        text = path.read_text()
    except FileNotFoundError:
        return None, None
    except OSError as err:
        return None, f"Could not read {path}: {err}"
    values = _parse(text)
    url = values.get("OPENTODO_URL", "")
    token = values.get("OPENTODO_TOKEN", "")
    if not url and not token:
        return None, None
    try:
        return validate(url, token, source=path), None
    except ConfigMissing as err:
        return None, str(err)


def _write_private(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".config-")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def save(cfg):
    """Write OPENTODO_URL and OPENTODO_TOKEN to config_path() with mode 600, keeping other lines."""
    cfg = validate(cfg.url, cfg.token)
    path = config_path()
    kept = []
    if path.exists():
        for line in path.read_text().splitlines():
            key, sep, _ = line.partition("=")
            if not (sep and not key.lstrip().startswith("#") and key.strip() in KEYS):
                kept.append(line)
    lines = [*kept, f"OPENTODO_URL={cfg.url}", f"OPENTODO_TOKEN={cfg.token}"]
    _write_private(path, "\n".join(lines) + "\n")
    return cfg


def clear():
    """Remove OpenTodo credentials from config_path(), switching back to standalone mode."""
    path = config_path()
    if not path.exists():
        return
    kept = []
    for line in path.read_text().splitlines():
        key, sep, _ = line.partition("=")
        if not (sep and not key.lstrip().startswith("#") and key.strip() in KEYS):
            kept.append(line)
    if any(line.strip() for line in kept):
        _write_private(path, "\n".join(kept) + "\n")
    else:
        path.unlink(missing_ok=True)


def safe_url(url):
    """True for https, or plain http to this machine."""
    parts = urllib.parse.urlsplit(url)
    if parts.scheme == "https" and parts.hostname:
        return True
    if parts.scheme != "http" or not parts.hostname:
        return False
    if parts.hostname == "localhost":
        return True
    try:
        return ipaddress.ip_address(parts.hostname).is_loopback
    except ValueError:
        return False


def database_path():
    directory = data_dir()
    directory.mkdir(parents=True, exist_ok=True)
    return directory / "dustpan.db"
