# Adds the portal probe to the T3 image. Build with tools/linux-desktop as the context:
#   docker build -f testbed/kde/probe.Dockerfile -t ld-t2-kde-probe:test .
# run.sh runs /opt/mouthtype/tools/linux-desktop/portal_probe.py when it exists.
ARG BASE=ld-t3-kde:test
FROM ${BASE}
USER root
COPY portal.py portal_probe.py /opt/mouthtype/tools/linux-desktop/
COPY share/app.mouthtype.Mouthtype.desktop /usr/share/applications/
# GIO drops a .desktop whose Exec program is not on PATH, and the portal then has no app info for the id.
RUN printf '#!/bin/sh\nexit 0\n' > /usr/bin/mouthtype-linux && chmod 0755 /usr/bin/mouthtype-linux
USER mouthtype
