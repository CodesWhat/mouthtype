# KDE acceptance image (item A2a): the T3 image plus the daemon sources. Build with tools/ as context (desktop.py imports the sibling linux-engine-proof):
#   docker build -f linux-desktop/testbed/kde/acceptance.Dockerfile -t ld-a2a-kde:test .
ARG BASE=ld-t3-kde:test
FROM ${BASE}
USER root
COPY linux-desktop/ /opt/mouthtype/tools/linux-desktop/
COPY linux-engine-proof/ /opt/mouthtype/tools/linux-engine-proof/
COPY linux-qt/ /opt/mouthtype/tools/linux-qt/
COPY omarchy-plugin/ /opt/mouthtype/tools/omarchy-plugin/
COPY linux-desktop/share/app.mouthtype.Mouthtype.desktop /usr/share/applications/
# GIO drops a .desktop whose Exec program is not on PATH, and the portal then has no app info for the id.
RUN printf '#!/bin/sh\nexit 0\n' > /usr/bin/mouthtype-linux && chmod 0755 /usr/bin/mouthtype-linux
COPY linux-desktop/testbed/kde/acceptance.sh /opt/testbed/
RUN chmod 0755 /opt/testbed/acceptance.sh
USER mouthtype
CMD ["/opt/testbed/acceptance.sh"]
