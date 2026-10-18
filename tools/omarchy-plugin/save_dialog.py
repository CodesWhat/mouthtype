#!/usr/bin/python3
"""Ask the desktop portal where to save a text file and print the chosen path.

The portal answers with a directed Response signal, so one connection must hold
both the request and the wait. This mirrors Omarchy's own file chooser helper.
"""

import argparse
import os
import sys

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

ANSWER_TIMEOUT_SEC = 600
EXIT_NOTHING_PICKED = 1
EXIT_CHOOSER_FAILED = 2


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--title", default="Save Text")
    parser.add_argument("--name", default="Transcript.txt")
    args = parser.parse_args()

    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    loop = GLib.MainLoop()
    uris = []

    def on_response(connection, sender, path, interface, signal, params):
        code, results = params.unpack()
        if code == 0:
            uris.extend(results.get("uris", []))
        loop.quit()

    def subscribe(path):
        bus.signal_subscribe("org.freedesktop.portal.Desktop", "org.freedesktop.portal.Request", "Response",
                             path, None, Gio.DBusSignalFlags.NONE, on_response)

    token = "mouthtype%d" % os.getpid()
    sender = bus.get_unique_name()[1:].replace(".", "_")
    predicted = "/org/freedesktop/portal/desktop/request/%s/%s" % (sender, token)
    subscribe(predicted)

    patterns = [(0, "*.txt"), (0, "*.TXT")]
    options = {
        "handle_token": GLib.Variant("s", token),
        "current_name": GLib.Variant("s", args.name),
        "filters": GLib.Variant("a(sa(us))", [("Text (*.txt)", patterns)]),
        "current_filter": GLib.Variant("(sa(us))", ("Text (*.txt)", patterns)),
    }
    handle = bus.call_sync("org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
                           "org.freedesktop.portal.FileChooser", "SaveFile",
                           GLib.Variant("(ssa{sv})", ("", args.title, options)),
                           None, Gio.DBusCallFlags.NONE, -1, None).unpack()[0]
    if handle != predicted:
        subscribe(handle)
    GLib.timeout_add_seconds(ANSWER_TIMEOUT_SEC, loop.quit)
    loop.run()

    for uri in uris[:1]:
        print(GLib.filename_from_uri(uri)[0])
    return 0 if uris else EXIT_NOTHING_PICKED


if __name__ == "__main__":
    try:
        sys.exit(main())
    except GLib.Error as error:
        print("save_dialog: %s" % error.message, file=sys.stderr)
        sys.exit(EXIT_CHOOSER_FAILED)
