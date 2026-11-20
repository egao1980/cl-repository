# syntax=docker/dockerfile:1
# GitHub Actions *job* container (jobs.<id>.container), not a Docker container action.
# Docker actions run isolated and cannot leave ros/sbcl on the runner for later steps.
# Docs: https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/run-jobs-in-a-container
#
# Linux / Ubuntu runners only. macOS / Windows stay on the VM (job containers are Linux-only).
FROM ubuntu:24.04

ARG SBCL_VERSION=2.6.7
ARG ROSWELL_VERSION=26.02.116
ARG CLIENT_VERSION=latest
ARG ORAS_VERSION=1.2.3

ENV DEBIAN_FRONTEND=noninteractive \
    HOME=/opt/cl-ci \
    ROSWELL_INSTALL_DIR=/usr/local \
    CL_CI_HOME=/opt/cl-ci \
    PATH="/usr/local/bin:/opt/cl-ci/.roswell/bin:${PATH}"

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash \
      bzip2 \
      ca-certificates \
      curl \
      libcurl4t64 \
      libzstd1 \
      make \
      python3 \
      tar \
      unzip \
 && rm -rf /var/lib/apt/lists/*

# Current git from the git-core PPA: noble ships 2.43, the VM runners 2.56
# (cl-repository#101; revision-backend-git needs >= 2.44 for git replay).
# apt reads an ASCII-armored .asc keyring directly, so no gnupg is needed.
ARG GIT_PPA_KEY=F911AB184317630C59970973E363C90F8F1B6217
RUN install -d -m 0755 /etc/apt/keyrings \
 && curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${GIT_PPA_KEY}" \
      -o /etc/apt/keyrings/git-core-ppa.asc \
 && . /etc/os-release \
 && echo "deb [signed-by=/etc/apt/keyrings/git-core-ppa.asc] https://ppa.launchpadcontent.net/git-core/ppa/ubuntu ${VERSION_CODENAME} main" \
      > /etc/apt/sources.list.d/git-core-ppa.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends git \
 && rm -rf /var/lib/apt/lists/* \
 && git --version

COPY docker/ci-base/install.sh /tmp/install.sh
COPY .github/actions/setup-client/setup-client.sh /tmp/setup-client.sh
COPY .github/actions/setup-roswell/fetch.sh /tmp/fetch.sh
# github_token: optional build secret (publish-ci-base.yml passes the job token).
# A secret mount never lands in a layer; GitHub throttles unauthenticated
# release downloads and GHCR pulls first.
RUN --mount=type=secret,id=github_token \
    chmod +x /tmp/install.sh \
 && GITHUB_TOKEN="$(cat /run/secrets/github_token 2>/dev/null || true)" \
    SBCL_VERSION="${SBCL_VERSION}" \
    ROSWELL_VERSION="${ROSWELL_VERSION}" \
    CLIENT_VERSION="${CLIENT_VERSION}" \
    ORAS_VERSION="${ORAS_VERSION}" \
    bash /tmp/install.sh \
 && rm -f /tmp/install.sh /tmp/setup-client.sh /tmp/fetch.sh

# Job containers: stay root (GHA mounts GITHUB_WORKSPACE). Do not set USER / ENTRYPOINT
# (container.options cannot pass --entrypoint).
# Default run shell inside a job container is `sh` unless the workflow sets shell: bash.
CMD ["/bin/bash"]
