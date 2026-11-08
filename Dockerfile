# postgres17-standalone in a container. Untested in the Zig rewrite: on a
# host without /dev/kvm in the container, h9 uses its native backend, which
# needs Syscall User Dispatch (Linux 5.11+) and a seccomp profile that
# allows it.
#
#   git submodule update --init
#   docker build -t postgres17-standalone .
#   docker run --rm -p 5432:5432 -e POSTGRES_PASSWORD=secret \
#     -v pgdata:/data --stop-timeout 60 postgres17-standalone

FROM alpine:3.23 AS build
ARG ZIG_VERSION=0.16.0
RUN apk add --no-cache curl jq tar xz make \
	&& curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-$(uname -m)-linux-${ZIG_VERSION}.tar.xz" \
		| tar -xJ -C /opt \
	&& ln -s /opt/zig-$(uname -m)-linux-${ZIG_VERSION}/zig /usr/local/bin/zig
WORKDIR /src
COPY . .
ARG VERSION=dev
RUN make build VERSION=${VERSION} OUT=/postgres17-standalone

FROM alpine:3.23
RUN adduser -D -h /home/postgres postgres \
	&& mkdir /data && chown postgres /data
COPY --from=build /postgres17-standalone /usr/local/bin/postgres17-standalone
USER postgres
VOLUME /data
EXPOSE 5432
ENTRYPOINT ["postgres17-standalone"]
CMD ["/data"]
