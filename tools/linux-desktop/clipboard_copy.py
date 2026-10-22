"""Clipboard copies for cards and Recent Takes on portal desktops.

On GNOME and KDE the daemon owns the RemoteDesktop/Clipboard portal session, so a copy goes to it over the service
socket and is offered with the password-manager hint. Anywhere else (Hyprland, Sway, no daemon, no grant) the caller
keeps its wl-copy path unchanged."""

import json
import os
from pathlib import Path

import backends

COPY_REPLY_SECONDS = 8


def configured_delivery(config_path):
    """desktop.delivery from the config file, 'auto' when it can't be read."""
    try:
        value = json.loads(Path(config_path).read_text(encoding='utf-8')).get('desktop', {}).get('delivery', 'auto')
    except (OSError, ValueError, AttributeError, TypeError):
        return 'auto'
    return value if value in backends.DELIVERY_NAMES else 'auto'


def portal_active(config_path=None, env=None):
    """True when this session's delivery backend is the portal one."""
    override = configured_delivery(config_path) if config_path else 'auto'
    try:
        return backends.delivery_name(backends.detect(os.environ if env is None else env), override) == 'portal'
    except (ValueError, KeyError):
        return False


def copy_via_portal(text, request, config_path=None, env=None, concealed=True):
    """Try the daemon's portal clipboard. request(action, **fields) is the service-socket call. True when the text
    is on the clipboard; False means the caller should copy the old way."""
    if not portal_active(config_path, env):
        return False
    try:
        reply = request('copy', text=text, concealed=concealed, reply_timeout=COPY_REPLY_SECONDS)
    except (OSError, ValueError):
        return False
    return isinstance(reply, dict) and reply.get('ok') is True
