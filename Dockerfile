FROM debian:bookworm-slim@sha256:7ff6ba31527b9e336162fa061746c366c4b2032f4d2cff2078bea43f78efe3f8

# systemd provides systemd-run, the D-Bus client for the host's systemd
# hadolint ignore=DL3008
RUN apt-get update \
	&& apt-get install -y --no-install-recommends systemd curl \
	&& rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/app
COPY distrust-roots.sh entrypoint.sh ./

CMD ["/usr/src/app/entrypoint.sh"]
