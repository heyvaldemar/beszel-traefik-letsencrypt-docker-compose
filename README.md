# Beszel + Traefik + Let's Encrypt on Docker Compose

[![Deployment Verification](https://github.com/heyvaldemar/beszel-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml/badge.svg?branch=main)](https://github.com/heyvaldemar/beszel-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

This repository deploys Beszel — a light server monitor with weeks of history and threshold alerts — behind Traefik with automatic Let's Encrypt TLS, with scheduled backups and a companion restore script.

Beszel answers one question: **is the host healthy?** CPU, memory, disk usage and I/O, network, temperature, S.M.A.R.T. disk health, per-container statistics. It does not tell you whether a service is *reachable* — a box at 10% CPU is useless information while the proxy returns 502s — and it does not show you *why* something broke. Three questions, three tools, no overlap.

## Getting started

```bash
# 1. Clone
git clone https://github.com/heyvaldemar/beszel-traefik-letsencrypt-docker-compose
cd beszel-traefik-letsencrypt-docker-compose

# 2. Create the two Docker networks the stack expects
docker network create traefik-network
docker network create beszel-network

# 3. Copy the environment template and fill in required values
cp .env.example .env
$EDITOR .env
# ^ Required: BESZEL_HOSTNAME, TRAEFIK_HOSTNAME,
#   TRAEFIK_ACME_EMAIL, TRAEFIK_BASIC_AUTH.
#   Leave BESZEL_AGENT_KEY and BESZEL_AGENT_TOKEN empty for now.

# 4. Deploy
docker compose -f beszel-traefik-letsencrypt-docker-compose.yml -p beszel up -d
```

### The agent will crash-loop, and that is the expected first state

The agent's key and token are issued by the hub, so they cannot exist before the hub has run once. Until you paste them in, the agent restarts every few seconds saying `no key provided`. Nothing is broken.

Finish it:

1. Open `https://<BESZEL_HOSTNAME>` and create your account.
2. **Add System.** Name it, and for **Host** paste `/beszel_socket/beszel.sock`.
3. Copy the key and the token it shows you into `BESZEL_AGENT_KEY` and `BESZEL_AGENT_TOKEN` in `.env`.
4. `docker compose -f beszel-traefik-letsencrypt-docker-compose.yml -p beszel up -d` again.

Step 2 is the one that looks wrong and is not. The hub reaches the agent over a **unix socket in a shared volume**, not over the network, and it has to: the agent runs with host networking and the hub does not, so neither can see the other's loopback and there is no Docker DNS name that resolves for both.

CI asserts that `no key provided` is the exact message a fresh agent produces — because "expected crash-loop" is a claim, and an unchecked claim about an expected failure is how a genuinely broken agent goes unnoticed for a week. A restarting container is precisely what the reader has been told to ignore.

### What success looks like

```bash
docker compose -f beszel-traefik-letsencrypt-docker-compose.yml -p beszel ps
curl -s "https://${BESZEL_HOSTNAME}/api/health"
# {"message":"API is healthy.","code":200,"data":{}}
```

After step 4, the system you added turns green in the interface and the charts start filling.

### Common first-deploy issues

- **The agent restarts forever.** Before step 4, expected. After it, check that both values were pasted whole — the key is an `ssh-ed25519 …` line.
- **Network graphs show almost nothing on a busy server.** The agent is not using host networking. Without it, it measures the container's interface rather than the machine's, which is a number that is wrong rather than missing.
- **Disk usage charts but the I/O chart is permanently flat.** `BESZEL_FILESYSTEM` is not a `/proc/diskstats` name. On LVM that is `dm-0`, not the `/dev/mapper` path.
- **No S.M.A.R.T. panel.** It needs `disk-smart.override.yml` and device nodes from your host. See below.
- **Cert issuance fails.** DNS has not propagated, or port 80 is not reachable from the internet.

## The agent image must be the `-alpine` variant

The base stack pins it, and this is why. The default agent image is built `FROM scratch`: no shell, no `smartctl`, and therefore no S.M.A.R.T. at all. It runs perfectly happily and silently monitors nothing about disk health — the failure mode where everything is green and the question is simply not being asked. Upstream says as much in its own documentation.

CI checks both halves: that the pinned reference carries `-alpine`, and that `smartctl` is actually in the image.

## Disks and S.M.A.R.T. are override files, deliberately

A device node belongs to your host. Naming `/dev/nvme0` in the base compose file means the stack refuses to start anywhere that node does not exist — not on a VPS, not on the CI runner that proves this template works, not on the laptop of anyone who clones it to try.

So the host-specific half lives in two files you opt into:

```bash
docker compose \
  -f beszel-traefik-letsencrypt-docker-compose.yml \
  -f disk-smart.override.yml \
  -f extra-filesystems.override.yml \
  -p beszel up -d
```

**`disk-smart.override.yml`** adds exactly two capabilities — `SYS_RAWIO` for SATA passthrough and `SYS_ADMIN` for NVMe — rather than `privileged: true`, which grants every capability on the host. It also spells out the thing people get wrong: pass the **controller**, not the block device or a partition (`/dev/nvme0`, not `/dev/nvme0n1`; `/dev/sda`, not `/dev/sda1`), and address USB disks by `/dev/disk/by-id` because USB enumeration reshuffles `sd?` letters between boots.

**`extra-filesystems.override.yml`** charts a second disk, and carries the trap worth knowing before you use it: Beszel watches a marker directory **on** the filesystem, and if that directory does not exist when the container starts, Docker creates it — as root, on whatever the path resolves to, which for an unmounted disk is your root filesystem. You then get a chart that looks entirely plausible and is measuring `/` a second time. Create the markers on the host first, and an unmounted disk gives you an empty graph, which is a question rather than a quiet lie.

## Neither the hub nor the agent has the Docker socket

The agent wants per-container CPU and memory, which needs container listing and inspection and nothing else — it never starts, stops or execs anything. `:ro` on a socket mount would not express that: the Docker API is root-equivalent whichever way the file is mounted.

So a proxy holds the socket and denies `POST`. It is published on `127.0.0.1` rather than reached by service name, because a host-networked container has no Docker DNS — loopback means nothing outside this machine can reach it. Checked on every CI run, along with both containers' mount lists:

| through the proxy | answer |
| :--- | :--- |
| `GET /containers/json` | `200` |
| `POST /containers/<id>/restart` | `403` |

## Updating

`./update.sh` moves this checkout to the latest release tag — a combination this repository's CI has booted, upgraded from the previous release on the same volumes, and smoke-tested — and then runs `docker compose up -d`. It refuses to cross a major version unattended, refuses to run over local changes, and names any variable that became required since your version before anything has moved.

If you run with the override files, add them to your own `up` command after the update: `update.sh` starts the base file only.

## Supply chain trust

Five images pinned to `tag@sha256:<digest>` as interpolation defaults in the compose `x-images` block: the hub, the `-alpine` agent, a Docker socket proxy, Traefik, and a plain alpine for the backups sidecar. `git pull` alone delivers the tested combination; an `*_IMAGE_TAG` variable in `.env` overrides deliberately.

The daily `check-pin-freshness` CI job re-resolves each pin against its registry and compares the pinned Beszel and Traefik versions against the latest upstream releases. GitHub Actions are pinned by commit SHA; Dependabot keeps those fresh.

## Production checklist

- [ ] **Finish the agent registration** (steps 1 to 4 above) — until then you are monitoring nothing.
- [ ] **Regenerate the Traefik dashboard hash.** The one in `.env.example` is a placeholder.
- [ ] **Set thresholds and alert rules.** A monitor nobody configured is a monitor nobody hears.
- [ ] **Send alerts somewhere off this machine.** If the host dies, so does anything running on it — including whatever would have told you.
- [ ] **Host-mount the backup volume.** By default the archives land in a named volume: if the host dies, they die with it.
- [ ] **Decide whether this faces the internet.** It describes your hardware and what runs on it.

## Backups and restore

The `backups` container archives the hub's data directory on a loop — a 30-minute warm-up, a 24-hour interval, 7-day retention, all overridable in `.env`. That is the systems, the alert rules, the users and the history. The history rides along and nobody restores a CPU graph from March; **the alert rules are the part that is genuinely irreplaceable**, and they are the reason this loop exists.

The agent's own directory is not archived — it is local state, rebuilt on start.

Each archive is written to a `.partial` name, **read back with `tar -tzf`**, and only then renamed. BusyBox tar returns exit code 1 both for "a file changed while I was reading it" and for "I could not write the output at all", and an archive truncated after tar exited still carries exit status 0.

```bash
chmod +x ./*.sh
./beszel-restore-data.sh
```

One caveat stated rather than hidden: tarring a live SQLite file under write load can produce a torn snapshot. At the write rate of a monitoring hub this is not a real risk, and the read-back would catch an archive that does not open — but if you want it airtight, stop the hub for the few seconds the tar takes.

## Resource limits

Every service carries memory and CPU limits plus reservations as compose-level defaults: the same values CI boots the stack under. They are small because Beszel is small. Override any of them in `.env` and the override survives every `git pull`.

## Container hardening

Every service runs with `security_opt: no-new-privileges:true` and `cap_drop: [ALL]`; Traefik adds back `NET_BIND_SERVICE` and the backups sidecar the three it needs to write archives it owns. The agent adds back nothing in the base stack, and exactly two capabilities when you opt into S.M.A.R.T. — which composes fine with `no-new-privileges`, because those are granted at container start rather than gained through a setuid binary.

## Testing

The [Deployment Verification](https://github.com/heyvaldemar/beszel-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml?query=branch%3Amain) workflow runs on every push, pull request, and every day at 06:00 UTC: shellcheck and actionlint, Trivy scans of all five pinned images, the daily freshness check, and a deploy job that requires the hub to answer through Traefik, **the agent to fail with the exact message this README documents and no other**, an account created from the CLI to sign in to the API, `/api/beszel/getkey` to hand back the ssh key that goes in `BESZEL_AGENT_KEY`, neither container to have the Docker socket among its mounts, the proxy to answer `403` to a POST and `200` to a GET, the pinned agent image to be the `-alpine` variant and to actually carry `smartctl`, an archive to be produced and to carry `data.db` by name, eight backup and restore scenarios to pass, and the hub to come back on the data directory the restore replaced underneath it.

The per-system token is minted by the interface when you add a system and cannot be fabricated from outside, which is why the README sends you there for it rather than pretending otherwise. Everything up to that point is checked.

```bash
chmod +x tests/e2e-backup-restore.sh
./tests/e2e-backup-restore.sh
```

Run it on a staging copy, not on production: it stops the hub and empties its data directory.

## Security notes

- Credentials are read from `.env` at deploy time; `.env` is gitignored and compose fails fast on missing required variables.
- The Docker socket is held by a proxy that denies every write, published on loopback only.
- The S.M.A.R.T. override adds two capabilities rather than `privileged: true`.

---

## About the maintainer

<div align="center">

**Maintained by [Vladimir Mikhalev](https://github.com/heyvaldemar)** · Docker Captain · IBM Champion · AWS Community Builder

[YouTube](https://www.youtube.com/channel/UCf85kQ0u1sYTTTyKVpxrlyQ?sub_confirmation=1) · [Blog](https://heyvaldemar.com) · [LinkedIn](https://www.linkedin.com/in/heyvaldemar/)

</div>
