# Omarchy-like Hyprland desktop for testing the Mouthtype Linux client.
# Real Omarchy (pinned release) on Arch's own packages, minus the parts that need hardware or systemd.
FROM archlinux:latest

# Omarchy v4.0.6. Bump the commit with the tag when moving to a newer release.
ARG OMARCHY_REF=237f1b4071a0bff2296c6d740ba2b9fd695ebfa0
ARG UID=1000

# DisableSandbox: pacman's download sandbox needs Landlock, which the NAS's 4.4 kernel lacks.
RUN sed -i 's/^#\?ParallelDownloads.*/ParallelDownloads = 3/' /etc/pacman.conf \
 && pacman -Syu --noconfirm --needed --disable-sandbox \
      hyprland hyprland-guiutils mutter quickshell wayvnc grim foot wtype wl-clipboard \
      pipewire pipewire-audio pipewire-pulse wireplumber \
      mesa vulkan-swrast libva-mesa-driver \
      python python-pip python-gobject python-pycryptodome gtk3 \
      curl ffmpeg libnotify jq socat git ruby libyaml imagemagick inotify-tools \
      procps-ng util-linux sudo dbus tzdata which gum \
      qt6-wayland qt6-svg qt6-imageformats qt6-5compat adwaita-icon-theme \
      noto-fonts noto-fonts-emoji ttf-jetbrains-mono-nerd woff2-font-awesome \
 && pacman -Scc --noconfirm \
 && rm -rf /var/cache/pacman/pkg/* /var/lib/pacman/sync/*

# The Omarchy tree goes where the omarchy package puts it, with its bin/ on PATH.
RUN git clone -q https://github.com/basecamp/omarchy /usr/share/omarchy \
 && git -C /usr/share/omarchy checkout -q "$OMARCHY_REF" \
 && rm -rf /usr/share/omarchy/.git \
 && for f in /usr/share/omarchy/bin/*; do ln -s "$f" /usr/local/bin/; done

COPY shims/ /opt/testbed/shims/
COPY hypr/ /opt/testbed/hypr/
COPY entrypoint.sh session.sh env.sh vnc-auth-proxy.py install.sh uninstall.sh smoke.sh sample.wav /opt/testbed/
COPY pipewire-virtual-mic.conf /opt/testbed/
RUN install -m 0755 /opt/testbed/shims/systemctl /usr/local/bin/systemctl \
 && install -m 0755 /opt/testbed/shims/systemd-cat /usr/local/bin/systemd-cat \
 && chmod 0755 /opt/testbed/*.sh /opt/testbed/vnc-auth-proxy.py \
 && useradd -m -u "$UID" -s /bin/bash omarchy \
 && install -d -o omarchy -g omarchy -m 0700 /run/user/$UID \
 && install -d -o omarchy -g omarchy /var/lib/testbed \
 && echo 'omarchy ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/omarchy

USER omarchy
ENV HOME=/home/omarchy \
    USER=omarchy \
    LANG=C.UTF-8 \
    XDG_RUNTIME_DIR=/run/user/1000 \
    XDG_SESSION_TYPE=wayland \
    XDG_CURRENT_DESKTOP=Hyprland \
    OMARCHY_PATH=/usr/share/omarchy \
    PATH=/home/omarchy/.local/bin:/usr/local/bin:/usr/bin:/usr/sbin:/usr/bin/site_perl:/usr/bin/vendor_perl:/usr/bin/core_perl

# Omarchy's default user config, its default theme rendered headless, and the first-run marker so the
# interactive provisioning step is skipped. The testbed overlay replaces only monitors.lua.
RUN mkdir -p ~/.config ~/.local/state/omarchy/current ~/.local/share \
 && cp -a /usr/share/omarchy/config/. ~/.config/ \
 && OMARCHY_THEME_HEADLESS=1 omarchy-theme-set "Tokyo Night" \
 && omarchy-done mark first-run-user \
 && cp /opt/testbed/hypr/monitors.lua ~/.config/hypr/monitors.lua \
 && mkdir -p ~/.config/pipewire/pipewire.conf.d \
 && cp /opt/testbed/pipewire-virtual-mic.conf ~/.config/pipewire/pipewire.conf.d/10-virtual-mic.conf

EXPOSE 5900
ENTRYPOINT ["/opt/testbed/entrypoint.sh"]
