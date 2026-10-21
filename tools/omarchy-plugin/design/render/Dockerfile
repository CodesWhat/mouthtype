FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      qt6-declarative-dev-tools qml6-module-qtquick qml6-module-qtquick-window qml6-module-qtquick-controls \
      qml6-module-qtquick-templates qml6-module-qtquick-layouts qml6-module-qtqml-workerscript qml6-module-qttest \
      qt6-svg-plugins qt6-qpa-plugins fontconfig fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/*
ENV QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software
WORKDIR /work
