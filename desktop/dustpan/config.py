"""Where the client keeps its settings and data (XDG base directories).

The config file holds KEY=VALUE lines: OPENTODO_URL and OPENTODO_TOKEN.
The URL must be https, except on this machine: the token travels in every request.
DUSTPAN_CONFIG and DUSTPAN_DATA override the paths, for development.
"""

import ipaddress
import os
import pathlib
import urllib.parse
from dataclasses import dataclass

APP_ID = "io.github.chizzler.Dustpan"


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


def load():
    path = config_path()
    try:
        text = path.read_text()
    except FileNotFoundError:
        raise ConfigMissing(f"no config at {path}") from None
    values = {}
    for line in text.splitlines():
        key, sep, value = line.partition("=")
        if sep and not key.lstrip().startswith("#"):
            values[key.strip()] = value.strip()
    if not values.get("OPENTODO_URL") or not values.get("OPENTODO_TOKEN"):
        raise ConfigMissing(f"{path} needs OPENTODO_URL and OPENTODO_TOKEN")
    if not safe_url(values["OPENTODO_URL"]):
        raise ConfigMissing(f"{path}: OPENTODO_URL must start with https:// (http only for localhost)")
    return Config(values["OPENTODO_URL"], values["OPENTODO_TOKEN"])


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
