ARG LINUX_386=linux/386

FROM --platform=$LINUX_386 postgres:17-alpine AS postgres-root
RUN echo "https://dl-cdn.alpinelinux.org/alpine/edge/testing" >> /etc/apk/repositories && \
    apk add -u bindfs

FROM alpine:latest AS postgres
RUN apk add --no-cache brotli
COPY --from=postgres-root / /root/
RUN tar -C /root -cf /root.tar . && brotli -j /root.tar

FROM ghcr.io/progrium/linux-build:latest AS kernel
COPY kernel.config .config
RUN make ARCH=i386 CROSS_COMPILE=i686-linux-gnu- oldconfig < /dev/null && \
    make ARCH=i386 CROSS_COMPILE=i686-linux-gnu- bzImage -j$(nproc)

