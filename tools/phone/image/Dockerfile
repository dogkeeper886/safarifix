FROM docker.io/library/ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      libimobiledevice-utils libusbmuxd-tools ideviceinstaller \
      python3 python3-websocket ca-certificates curl git \
      build-essential autoconf automake libtool pkg-config \
      libimobiledevice-dev libplist-dev libusbmuxd-dev libssl-dev \
    && rm -rf /var/lib/apt/lists/*
# ios-webkit-debug-proxy isn't packaged for 24.04; build the pinned release.
RUN git clone --depth 1 --branch v1.9.2 https://github.com/google/ios-webkit-debug-proxy /src/iwdp \
    && cd /src/iwdp && test "$(git rev-parse HEAD)" = 278bf4874e6d3d3599baa90e1c59f7ac48bb8b1b \
    && ./autogen.sh && make -j"$(nproc)" && make install && ldconfig && rm -rf /src/iwdp
COPY openssl.cnf /etc/iphone-openssl.cnf
ENV OPENSSL_CONF=/etc/iphone-openssl.cnf
