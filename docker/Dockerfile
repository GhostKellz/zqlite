# ZQLite Testing Environment - Lightweight
# Mounts host Zig, no download needed

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/zqlite

CMD ["zig", "build", "test"]
