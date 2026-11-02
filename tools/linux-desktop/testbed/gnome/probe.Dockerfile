# Adds the portal probe to the T1 image. Build with tools/linux-desktop as the context:
#   docker build -f testbed/gnome/probe.Dockerfile -t ld-t2-probe:test .
ARG BASE=ld-t1-gnome:test
FROM ${BASE}
COPY portal.py portal_probe.py atspi_target.py consent_atspi.py /opt/mouthtype/tools/linux-desktop/
COPY share/app.mouthtype.Mouthtype.desktop /usr/share/applications/
# GIO drops a .desktop whose Exec program is not on PATH, and the portal then has no app info for the id.
RUN printf '#!/bin/sh\nexit 0\n' > /usr/bin/mouthtype-linux && chmod 0755 /usr/bin/mouthtype-linux
COPY testbed/gnome/probe.sh testbed/gnome/entrypoint.sh /opt/testbed/
RUN chmod 0755 /opt/testbed/probe.sh /opt/testbed/entrypoint.sh
ENV MOUTHTYPE_TESTBED_SCRIPT=probe.sh
