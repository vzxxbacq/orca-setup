# The Orca server image (README section 6.7): Orca's headless runtime and every agent for a Linux server, published
# as ghcr.io/vzxxbacq/orca-server by .github/workflows/ci.yml. Built from the repository root:
#   docker build --file docker/Dockerfile .
# No package list lives here: docker/build.sh installs everything from manifest/ through the lib/ code setup.sh uses.
# The base image is pinned by digest (ubuntu:24.04, linux/amd64 among its platforms).
FROM ubuntu:24.04@sha256:68ee22004a9109b44973313b02ff7b1de250f1de0f5ecb628d73f579aaff33ac

LABEL org.opencontainers.image.source=https://github.com/vzxxbacq/orca-setup \
      org.opencontainers.image.description="Orca server for orca-setup: Orca's headless runtime and the agent CLIs" \
      org.opencontainers.image.licenses=MIT

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# What the tool installation reads comes first, so documentation changes keep the cached tool layer.
COPY lib /opt/orca-setup/lib
COPY manifest /opt/orca-setup/manifest
COPY docker/build.sh /opt/orca-setup/docker/build.sh
RUN ORCA_SETUP_IMAGE_BUILD=1 bash /opt/orca-setup/docker/build.sh

# A copy of this repository's scripts for the checks and logins setup.sh runs inside the container.
COPY . /opt/orca-setup

ENV ORCA_SETUP_CONTAINER=orca-server \
    PATH=/opt/orca-agents/.local/bin:/opt/orca-agents/.grok/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    DISABLE_AUTOUPDATER=1 \
    LANG=C.UTF-8

ENTRYPOINT ["/opt/orca-setup/docker/entrypoint.sh"]
# compose.yaml (rendered by setup.sh) gives the full command with the pairing address.
CMD ["orca-ide", "serve", "--supervise", "--no-pairing", "--port", "6768"]
