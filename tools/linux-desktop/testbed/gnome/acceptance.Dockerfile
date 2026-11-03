# GNOME acceptance image (item A1): the T1 image plus the daemon sources. Build with tools/ as context (desktop.py imports the sibling linux-engine-proof):
#   docker build -f linux-desktop/testbed/gnome/acceptance.Dockerfile -t ld-a1-gnome:test .
ARG BASE=ld-t1-gnome:test
FROM ${BASE}
COPY linux-desktop/ /opt/mouthtype/tools/linux-desktop/
COPY linux-engine-proof/ /opt/mouthtype/tools/linux-engine-proof/
COPY linux-desktop/share/app.mouthtype.Mouthtype.desktop /usr/share/applications/
# GIO drops a .desktop whose Exec program is not on PATH, and the portal then has no app info for the id.
RUN printf '#!/bin/sh\nexit 0\n' > /usr/bin/mouthtype-linux && chmod 0755 /usr/bin/mouthtype-linux
COPY linux-desktop/testbed/gnome/acceptance.sh linux-desktop/testbed/gnome/entrypoint.sh /opt/testbed/
RUN chmod 0755 /opt/testbed/acceptance.sh /opt/testbed/entrypoint.sh
ENV MOUTHTYPE_TESTBED_SCRIPT=acceptance.sh
