# Local CI Testing with Docker and act

Run the repository's GitHub Actions workflows locally with Docker + `act`.

## Prerequisites

- Docker daemon running
- `act` installed (`brew install act` on macOS)
- Roswell + qlot available if you also run tests directly from shell

## 1) Sanity-check local toolchain

```sh
docker info >/dev/null
act --version
qlot install
```

## 2) Run tests directly (fast feedback)

```sh
qlot exec ros -e '(asdf:test-system "cl-repository-packager")'
qlot exec ros -e '(asdf:test-system "cl-repository-client")'
qlot exec ros -e '(asdf:test-system "cl-repository-integration-tests")'
```

For integration tests, start a local registry first if it is not running:

```sh
docker rm -f oci-registry 2>/dev/null || true
docker run -d --name oci-registry -p 5050:5000 registry:2
```

## 3) Run `.github/workflows/test.yml` with `act`

Use a compatible Ubuntu image:

```sh
act -W .github/workflows/test.yml \
  -P ubuntu-latest=ghcr.io/catthehacker/ubuntu:act-latest
```

Run specific jobs:

```sh
act -W .github/workflows/test.yml -j test \
  -P ubuntu-latest=ghcr.io/catthehacker/ubuntu:act-latest

act -W .github/workflows/test.yml -j integration \
  -P ubuntu-latest=ghcr.io/catthehacker/ubuntu:act-latest
```

## 4) Run publish workflow locally (`.github/workflows/publish.yml`)

The publish workflow needs a tag ref and a token.

Create an event payload:

```sh
cat > /tmp/act-publish-event.json <<'JSON'
{
  "ref": "refs/tags/v0.0.1",
  "ref_name": "v0.0.1",
  "repository": {
    "full_name": "my-org/my-project",
    "name": "my-project",
    "owner": { "login": "my-org" }
  },
  "actor": "local-user"
}
JSON
```

Run publish with a token (for GHCR pushes):

```sh
act push \
  -W .github/workflows/publish.yml \
  -e /tmp/act-publish-event.json \
  -s GITHUB_TOKEN="$GITHUB_TOKEN" \
  -P ubuntu-latest=ghcr.io/catthehacker/ubuntu:act-latest
```

If you only want to validate workflow steps without publishing, set a dummy token and expect push/verify steps to fail at registry auth.

## 5) Common troubleshooting

- `Cannot connect to Docker daemon`: start Docker Desktop / daemon.
- Roswell install failures inside `act`: rerun with latest runner image mapping (`-P ...act-latest`).
- Slow first run: container image pulls are expected.
- Publish auth failures: ensure `GITHUB_TOKEN`/PAT has `write:packages`.

## 6) Cleanup

```sh
docker rm -f oci-registry 2>/dev/null || true
```
