# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Traefik's timeouts also answer to the fleet-wide names.**
  `TRAEFIK_READ_TIMEOUT`, `TRAEFIK_WRITE_TIMEOUT` and `TRAEFIK_IDLE_TIMEOUT` now
  set the HTTPS entry point's timeouts here as in every other Traefik template
  in the fleet. When set they win; `BESZEL_READ_TIMEOUT`, `BESZEL_WRITE_TIMEOUT`, `BESZEL_IDLE_TIMEOUT` keep working exactly as before,
  and a deployment that sets neither gets the same defaults.

## [1.0.3] - 2026-09-23

### Fixed

- **CI had never run the restore script.** The test restored with its own
  copy of the commands. The script read `DATA_PATH` and `DATA_BACKUPS_PATH`
  from the shell that ran it rather than from `.env` or the stack, so a path
  set in `.env` was not the one it listed or cleared, and it cleared with
  `rm -rf dir/*`, which leaves every dotfile of the newer state in place. It
  now takes every path and name from the running backups container, accepts
  the backup file name as an argument, starts the application again whatever
  happens, and CI runs it: a file written before a backup and deleted after it
  must be back once that backup is restored.

### Changed

- **The freshness check has its own workflow, Pin Freshness.** It ran inside Deployment Verification, whose badge is the one at the top of this README. Across the fleet, nine red runs in ten were a pin one version behind - which the fleet's triage moves within the day - and a reader cannot tell that from a stack that does not boot. The badge now says whether the stack boots. The job itself is unchanged.

## [1.0.2] - 2026-09-21

### Security

- **`traefik:3.7` was rebuilt upstream**; the pin moved from `sha256:1c32e7c36820…` to `sha256:24841fe2de73…`. Same version, same tag, a rebuilt base image — the usual shape of a security fix in a base layer.

## [1.0.1] - 2026-09-20

### Changed

- **`henrygd/beszel:0.19.0` moved to `henrygd/beszel:0.20.0`.** The freshness check reported the lag; the deploy job booted the stack on the new image before this landed.
- **`henrygd/beszel-agent:0.19.0-alpine` moved to `henrygd/beszel-agent:0.20.0-alpine`.** The freshness check reported the lag; the deploy job booted the stack on the new image before this landed.

### Security

- **`traefik:3.7` was rebuilt upstream**; the pin moved from `sha256:f86a2cab1b5c…` to `sha256:1c32e7c36820…`. Same version, same tag, a rebuilt base image — the usual shape of a security fix in a base layer.
- **`alpine:3.22` was rebuilt upstream**; the pin moved from `sha256:14358309a308…` to `sha256:5291449c3df7…`. Same version, same tag, a rebuilt base image — the usual shape of a security fix in a base layer.

## [1.0.0] - 2026-09-11

First release. A production deployment of Beszel behind Traefik, built to the
fleet standard established in
[keycloak-traefik-letsencrypt-docker-compose](https://github.com/heyvaldemar/keycloak-traefik-letsencrypt-docker-compose).

### Added

- **Beszel 0.19 behind Traefik with Let's Encrypt TLS.** Five images pinned by
  `tag@sha256:<digest>` in the compose `x-images` block: the hub, the agent, a
  Docker socket proxy, Traefik, and a plain alpine for the backups sidecar.
- **The agent pinned to the `-alpine` variant, which is a requirement and not a
  preference.** The default agent image is built `FROM scratch`: no shell, no
  `smartctl`, and therefore no S.M.A.R.T. at all. It runs perfectly happily and
  silently monitors nothing about disk health — everything green, the question
  simply not asked. CI checks both halves: that the pinned reference carries
  `-alpine`, and that `smartctl` is in the image.
- **CI asserts the expected crash-loop is the expected one.** The agent's key
  and token are issued by the hub and cannot exist before it has run, so a
  fresh agent restarts every few seconds saying `no key provided`. The README
  tells you to ignore that — and an unchecked claim about an expected failure
  is how a genuinely broken agent goes unnoticed for a week, because a
  restarting container is precisely what the reader has been told to ignore. So
  the message is asserted, and any other reason fails the build.
- **The registration path checked as far as it can honestly be checked.** The
  deploy job creates an account from the CLI, signs in to the API with it, and
  reads back the ssh key that goes in `BESZEL_AGENT_KEY`. The per-system token
  is minted by the interface when you add a system and cannot be fabricated
  from outside; the README sends you there for it rather than pretending
  otherwise.
- **Neither the hub nor the agent holds the Docker socket.** A proxy holds it
  and denies `POST` — published on `127.0.0.1` rather than reached by service
  name, because a host-networked container has no Docker DNS to resolve one
  with. CI asserts the proxy's answers and both containers' mount lists.
- **S.M.A.R.T. and extra filesystems as opt-in override files.** A device node
  belongs to your host: naming `/dev/nvme0` in the base file means the stack
  refuses to start anywhere that node does not exist, including the CI runner
  that proves this template works.
- **A backup loop that reads its own archive back before naming it a backup**,
  an end-to-end suite requiring `data.db` in the archive by name, a restore
  script, `update.sh`, resource limits and reservations, and OpenSSF Scorecard.

### Notes

- **The hub reaches the agent over a unix socket, not the network**, and that
  is forced rather than chosen: the agent runs with host networking and the hub
  does not, so neither can see the other's loopback and no Docker DNS name
  resolves for both. This is why `Host` in the Add System dialog is
  `/beszel_socket/beszel.sock` and not an address.
- **Host networking on the agent is required.** Without it the agent measures
  the container's network interface rather than the machine's and reports a
  busy server as idle — a number that is wrong rather than missing, which is
  worse.
- **`FILESYSTEM` must be a `/proc/diskstats` name.** `dm-0` on LVM, not the
  `/dev/mapper` path; `md0` for a software array. Get it wrong and you see disk
  usage with a permanently flat I/O chart.
- **Create the marker directories before using the extra-filesystems
  override.** Beszel charts a filesystem by watching a marker directory on it,
  and if that directory does not exist at container start, Docker creates it —
  as root, on whatever the path resolves to, which for an unmounted disk is the
  root filesystem. You get a chart that looks plausible and is measuring `/` a
  second time. With the marker on the disk itself, an unmounted disk gives an
  empty graph, which is a question rather than a quiet lie.
- **S.M.A.R.T. needs two capabilities, not `privileged: true`.** `SYS_RAWIO`
  for SATA passthrough and `SYS_ADMIN` for NVMe. They compose fine with
  `no-new-privileges`, because they are granted at container start rather than
  gained through a setuid binary.
- **Pass the controller, not the block device or a partition.** `/dev/nvme0`,
  not `/dev/nvme0n1`; `/dev/sda`, not `/dev/sda1`. And address USB disks by
  `/dev/disk/by-id`, because USB enumeration reshuffles `sd?` letters between
  boots.
- **Tarring a live SQLite file under write load can produce a torn snapshot.**
  At a monitoring hub's write rate this is not a real risk, and the read-back
  would catch an archive that does not open. Stop the hub for the few seconds
  the tar takes if you want it airtight.

[Unreleased]: https://github.com/heyvaldemar/beszel-traefik-letsencrypt-docker-compose/compare/v1.0.2...HEAD
[1.0.2]: https://github.com/heyvaldemar/beszel-traefik-letsencrypt-docker-compose/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/heyvaldemar/beszel-traefik-letsencrypt-docker-compose/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/heyvaldemar/beszel-traefik-letsencrypt-docker-compose/releases/tag/v1.0.0
