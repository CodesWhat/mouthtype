# GNOME 50 headless testbed for the Ubuntu 26.04 desktop work (item T1).
FROM ubuntu:26.04@sha256:c098726dd9b9733f3e885f8de0ef375206a311b0a317eadc40d347b1115fb944

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      gnome-shell mutter gnome-control-center gnome-shell-extensions \
      xdg-desktop-portal xdg-desktop-portal-gnome \
      pipewire wireplumber at-spi2-core dbus dbus-user-session systemd \
      python3 python3-jeepney python3-gi gir1.2-atspi-2.0 gir1.2-gtk-3.0 \
      ca-certificates \
 && apt-cache policy gnome-shell-extension-appindicator > /opt/appindicator-policy.txt \
 && (apt-get install -y --no-install-recommends gnome-shell-extension-appindicator || true) \
 && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --shell /bin/bash tester
COPY run.sh probe.sh entrypoint.sh /opt/testbed/
RUN chmod 0755 /opt/testbed/run.sh /opt/testbed/probe.sh /opt/testbed/entrypoint.sh
ENTRYPOINT ["/opt/testbed/entrypoint.sh"]
