# Headless KDE Plasma Wayland session on Fedora 44 for the Mouthtype portal work.
# Runs kwin_wayland --virtual plus xdg-desktop-portal-kde, no GPU, no systemd.
FROM fedora:44@sha256:43b29f65a41eb9c35e1cd5323e3bdf3b655c2357a9f4f1ff2f9c2798e5045d80

ARG UID=1000

# tsflags=nocaps: the NAS test engine's storage can't set file capabilities (cap_set_file fails).
RUN dnf -y --setopt=install_weak_deps=False --setopt=tsflags=nocaps install \
      kwin-wayland xdg-desktop-portal xdg-desktop-portal-kde \
      plasma-workspace layer-shell-qt \
      pipewire pipewire-pulseaudio wireplumber \
      at-spi2-core dbus-daemon dbus-tools \
      python3 python3-jeepney python3-gobject gtk3 \
      mesa-dri-drivers mesa-libEGL mesa-libgbm \
      qt6-qtwayland qt6-qtdeclarative qt6-qtsvg python3-pyside6 procps-ng sudo jq \
 && dnf clean all \
 && rm -rf /var/cache/dnf

COPY run.sh seed-permission-store.py /opt/testbed/
RUN chmod 0755 /opt/testbed/run.sh /opt/testbed/seed-permission-store.py \
 && useradd -m -u "$UID" -s /bin/bash mouthtype \
 && install -d -o mouthtype -g mouthtype -m 0700 /run/user/$UID \
 && install -d -o mouthtype -g mouthtype /var/lib/testbed

USER mouthtype
ENV XDG_RUNTIME_DIR=/run/user/1000 \
    XDG_SESSION_TYPE=wayland \
    XDG_CURRENT_DESKTOP=KDE \
    KDE_FULL_SESSION=true \
    QT_QPA_PLATFORM=wayland \
    LIBGL_ALWAYS_SOFTWARE=1
WORKDIR /home/mouthtype
CMD ["/opt/testbed/run.sh"]
