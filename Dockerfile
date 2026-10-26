ARG LINUX_386=linux/386

FROM --platform=$LINUX_386 postgres:17-alpine AS postgres-root
RUN apk add -u e2fsprogs

FROM alpine:latest AS postgres-compress
RUN apk add --no-cache brotli
COPY --from=postgres-root / /root/
RUN tar -C /root -cf /root.tar . && brotli -q 10 -j /root.tar

FROM scratch AS postgres-export
COPY --from=postgres-compress /root.tar.br /

FROM ghcr.io/progrium/linux-build:latest AS kernel
COPY kernel.config .config
RUN make ARCH=i386 CROSS_COMPILE=i686-linux-gnu- oldconfig < /dev/null && \
    make ARCH=i386 CROSS_COMPILE=i686-linux-gnu- bzImage -j$(nproc)

FROM scratch AS kernel-export
COPY --from=kernel /build/arch/x86/boot/bzImage /
# postgres17-standalone in a container: Alpine with WebKitGTK and Xvfb, which
# the binary starts itself since there is no display.
#
#   docker build -t postgres17-standalone .
#   docker run --rm -p 5432:5432 -e POSTGRES_PASSWORD=secret \
#     -v pgdata:/data --stop-timeout 60 postgres17-standalone

# Built with cgo against musl, since purego without cgo needs glibc.
FROM golang:1.27-alpine AS build
RUN apk add --no-cache gcc musl-dev
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
COPY --from=postgres-export /root.tar.br assets/
COPY --from=kernel-export /bzImage assets/
ARG VERSION=dev
RUN CGO_ENABLED=1 go build -trimpath -ldflags="-s -w -X main.Version=${VERSION}" -o /postgres17-standalone .

FROM alpine:3.23
# mesa-dri-gallium gives GTK a software GL driver (llvmpipe) under Xvfb.
RUN apk add --no-cache webkit2gtk-4.1 xvfb font-dejavu mesa-dri-gallium \
	&& adduser -D -h /home/postgres postgres \
	&& mkdir /data && chown postgres /data
COPY --from=build /postgres17-standalone /usr/local/bin/postgres17-standalone
USER postgres
VOLUME /data
EXPOSE 5432
ENTRYPOINT ["postgres17-standalone"]
CMD ["/data"]
