# GNOME acceptance image (item A1): the T1 image plus the daemon sources. Build with tools/linux-desktop as context:
#   docker build -f testbed/gnome/acceptance.Dockerfile -t ld-a1-gnome:test .
ARG BASE=ld-t1-gnome:test
FROM ${BASE}
COPY . /opt/mouthtype/tools/linux-desktop/
COPY share/app.mouthtype.Mouthtype.desktop /usr/share/applications/
# GIO drops a .desktop whose Exec program is not on PATH, and the portal then has no app info for the id.
RUN printf '#!/bin/sh\nexit 0\n' > /usr/bin/mouthtype-linux && chmod 0755 /usr/bin/mouthtype-linux
COPY testbed/gnome/acceptance.sh testbed/gnome/entrypoint.sh /opt/testbed/
RUN chmod 0755 /opt/testbed/acceptance.sh /opt/testbed/entrypoint.sh
ENV MOUTHTYPE_TESTBED_SCRIPT=acceptance.sh
