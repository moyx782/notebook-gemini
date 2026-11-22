# Multi-arch Linux package builder for SyncCanvas Notebook (.deb, .rpm, .AppImage)
FROM ubuntu:24.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    unzip \
    xz-utils \
    zip \
    clang \
    cmake \
    ninja-build \
    pkg-config \
    libgtk-3-dev \
    liblzma-dev \
    build-essential \
    dpkg-dev \
    rpm \
    squashfs-tools \
    file \
    desktop-file-utils \
    poppler-utils \
    && rm -rf /var/lib/apt/lists/*

RUN git clone https://github.com/flutter/flutter.git -b stable --depth 1 /opt/flutter
ENV PATH="/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:${PATH}"
RUN flutter --suppress-analytics precache --linux

WORKDIR /src
COPY . .
RUN chmod +x ./scripts/build_linux_packages.sh && ./scripts/build_linux_packages.sh

FROM scratch AS export
COPY --from=builder /src/dist/linux/ /
