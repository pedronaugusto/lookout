FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends curl xz-utils ca-certificates && rm -rf /var/lib/apt/lists/*
ARG ZIG=0.16.0
RUN set -e; arch=$(uname -m); \
    for name in "zig-${arch}-linux-${ZIG}" "zig-linux-${arch}-${ZIG}"; do \
      if curl -fsSL "https://ziglang.org/download/${ZIG}/${name}.tar.xz" -o /tmp/zig.tar.xz; then break; fi; done; \
    mkdir -p /opt/zig && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 && rm /tmp/zig.tar.xz
ENV PATH=/opt/zig:$PATH
WORKDIR /src
