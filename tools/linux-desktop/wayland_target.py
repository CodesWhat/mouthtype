"""Synthetic GTK Wayland target for explicit remote component acceptance."""

import json
import os
from pathlib import Path
import sys

import gi
gi.require_version('Gdk', '3.0')
gi.require_version('Gtk', '3.0')
from gi.repository import Gdk, Gtk, GLib


def activate(app):
    GLib.set_prgname('app.mouthtype.Acceptance')
    window = Gtk.ApplicationWindow(application=app)
    window.set_default_size(800, 400)
    destination = Path(sys.argv[1])
    if os.environ.get('MOUTHTYPE_TARGET_SECURE'):
        # A password entry, which AT-SPI reports as a password text field.
        editor = Gtk.Entry()
        editor.set_visibility(False)
        buffer = editor
        def changed(current):
            destination.write_text(json.dumps({'text': current.get_text()}, ensure_ascii=False))
        editor.connect('changed', changed)
    else:
        editor = Gtk.TextView()
        buffer = editor.get_buffer()
        def changed(current):
            text = current.get_text(current.get_start_iter(), current.get_end_iter(), True)
            destination.write_text(json.dumps({'text': text}, ensure_ascii=False))
        buffer.connect('changed', changed)
    sentinel = os.environ.get('MOUTHTYPE_TARGET_CLIPBOARD')
    if sentinel:
        # An earlier selection owned by another client, so a clipboard restore has something to put back.
        # Wayland only accepts a selection with an input serial, so it is set on a Shift_L press.
        def on_key(widget, event):
            if event.keyval == Gdk.KEY_Shift_L:
                Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).set_text(sentinel, -1)
            return False
        window.connect('key-press-event', on_key)
    window.add(editor)
    window.show_all()
    editor.grab_focus()
    changed(buffer)


app = Gtk.Application(application_id='app.mouthtype.Acceptance')
app.connect('activate', activate)
sys.exit(app.run(['app.mouthtype.Acceptance']))
