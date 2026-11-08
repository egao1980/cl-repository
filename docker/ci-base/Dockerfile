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
      git \
      libcurl4t64 \
      libzstd1 \
      make \
      python3 \
      tar \
      unzip \
 && rm -rf /var/lib/apt/lists/*

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
