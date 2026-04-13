# ZQLite testing environment
# Uses Alpine, host networking, and host Zig bind only.

FROM alpine:latest

RUN apk add --no-cache \
    bash \
    build-base \
    ca-certificates \
    git \
    linux-headers \
    musl-dev

WORKDIR /workspace/zqlite

COPY . /workspace/zqlite

CMD ["/opt/zig/zig", "build", "test"]
