"""Synthetic GTK Wayland target for explicit remote component acceptance."""

import json
from pathlib import Path
import sys

import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, GLib


def activate(app):
    GLib.set_prgname('app.mouthtype.Acceptance')
    window = Gtk.ApplicationWindow(application=app)
    window.set_default_size(800, 400)
    editor = Gtk.TextView()
    buffer = editor.get_buffer()
    destination = Path(sys.argv[1])
    def changed(current):
        text = current.get_text(current.get_start_iter(), current.get_end_iter(), True)
        destination.write_text(json.dumps({'text': text}, ensure_ascii=False))
    buffer.connect('changed', changed)
    window.add(editor)
    window.show_all()
    editor.grab_focus()
    changed(buffer)


app = Gtk.Application(application_id='app.mouthtype.Acceptance')
app.connect('activate', activate)
sys.exit(app.run(['app.mouthtype.Acceptance']))
