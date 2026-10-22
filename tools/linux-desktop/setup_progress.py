"""Throttled, monotonic download progress written to a status file for the panel to read."""

import json
import os
from pathlib import Path
import time


def write_atomic(path, **fields):
    path = Path(path)
    fields['updated'] = time.time()
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(fields))
    os.replace(tmp, path)


class DownloadProgress:
    """Callable taking bytes downloaded so far. Hands `emit(bytes_done, bytes_total)` at most twice a second.

    Reported bytes never decrease and never pass the total, and the first and final values always go through."""

    def __init__(self, total, emit, *, interval=0.5, clock=time.monotonic):
        self.total, self.emit, self.interval, self.clock = int(total), emit, interval, clock
        self.done = 0
        self.last = None
        self.reported = -1

    def __call__(self, done, *, final=False):
        self.done = max(self.done, min(int(done), self.total))
        now = self.clock()
        if not final and self.last is not None and now - self.last < self.interval:
            return
        if self.done == self.reported:
            return
        self.last, self.reported = now, self.done
        self.emit(self.done, self.total)

    def finish(self):
        self(self.total, final=True)
