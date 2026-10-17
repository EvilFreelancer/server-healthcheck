---
name: server-healthcheck
description: >
  Check whether a host of a fleet harness repository is healthy, or check every
  machine of a whole namespace. Use when the user asks if a server is OK, alive,
  healthy or broken, asks to check, verify, smoke-test or audit a box or a namespace,
  asks what survived a power cut, a reboot, a network blip or a maintenance window,
  or reports that something "looks up but does not work". Read-only: it diagnoses
  and reports, it never repairs.
metadata:
  version: 0.1.0
  author: Pavel Rykov <paul@drteam.rocks>
  homepage: https://github.com/EvilFreelancer/server-healthcheck
  triggers: >
    health check, healthcheck, is the server ok, server down, audit server,
    smoke test, after power cut, after reboot, looks up but does not work,
    namespace health, проверить сервер, аудит сервера, что пережило отключение
---

# Server health check

This skill reads the host cards of the harness and needs the `server-discovery` skill
next to it for the drift check ([host-card.md](../server-discovery/references/host-card.md)
describes the card). Read the harness's own instructions (`AGENTS.md` and the rules it
lists) first. The commands spell the skills as `.agents/skills/<skill>/`, the
project-level install; use the real prefix when they live elsewhere. Nothing below
changes a host.

## Core principle

**`Up` is not healthy.** Docker says `Up` for a container whose resolver is empty, whose
CUDA context died, or whose model is still loading. A process being alive proves nothing.
A host is healthy when three statements hold at once:

1. the box itself is sound (came up cleanly, disks writable, no failed units, no Xid);
2. every service that is supposed to run answers a **real request**, not a port scan;
3. the live facts still match the frontmatter card and the README body.

Anything you cannot demonstrate is not a finding. Anything the card claims and the box
denies is.

## Read-only, always

Diagnose, report, then ask. Restarting a container "just to see" destroys the evidence
and costs the users a model reload, minutes of downtime per box on an inference fleet.
If the fix is obvious, say what you would do and wait for a yes. The only exception is a
probe that a service is designed to answer (`GET /v1/models`, a one-token completion, an
embedding of a short string).

## Inputs

- a host (`node1`, or `<namespace>/<host>` when the name is ambiguous), or
- a namespace (`lab`), meaning every host in it, or
- nothing, meaning ask which.

Resolve a bare name across the top-level directories of the harness. Several matches:
stop and ask.

## Procedure for one host

Each step is a gate. A failing gate is a finding, not a reason to stop: record it and
carry on, because the point is a complete picture.

### 1. Read before connecting

Read `<namespace>/<host>/README.md` in full and the namespace README. The card gives the
exact `ssh` command, the `jump`, and the facts to compare against. The body gives the
ports, the stacks and the incidents this box has had before. `status: retired` means do
not connect. `status: pending` means expect `null` fields, say so instead of reporting
drift.

### 2. Reachability

```bash
timeout 20 <ssh from the card> -o BatchMode=yes -o ConnectTimeout=8 'echo ok'
```

**The folder name is not an ssh target.** Run the `ssh` field verbatim, never `ssh <folder
name>`: a router may be reached as `ssh -l root 10.0.0.1`, a NAS as
`ssh -p 2222 ops@10.0.0.20`, and guessing the login gets you a `Permission denied` you
will then misread as the host being down. The card also decides the user: an appliance
where the only account is `root` needs that account, and `sudo: root` in the card is the
sign.

A password prompt or `Permission denied` is a finding, not something to work around: ask
the user to run `ssh-copy-id`. If the card describes the machine you are running on, run
the checks locally instead of over ssh.

### 3. Host-level pass

```bash
<ssh from the card> sh -s < .agents/skills/server-healthcheck/scripts/healthcheck.sh
```

One read-only pass: boot history and whether this boot followed an unclean shutdown,
clock sync, failed units, disk usage and read-only remounts, kernel I/O errors, OOM
kills, container states, restart counts, container resolvers, published ports without a
listener, NVIDIA GPU count against the PCI bus (cards without `nvidia-smi` are a `FAIL`
that names the bound kernel driver), ECC, Xid, Intel discrete GPUs without an i915/xe
driver or a render node, and PCIe AER of every GPU. It prints `PASS`, `WARN`, `FAIL`,
`SKIP` and exits non-zero on any `FAIL`. `SKIP` is not a failure: it runs on busybox and
Synology too, where most of it does not apply. Its unit tests are in `tests/` next to
this file.

### 4. Card drift

```bash
python3 .agents/skills/server-discovery/scripts/discover.py --ssh "<ssh from the card>"
```

Compare its JSON with the frontmatter: `os`, `kernel`, `docker`, `driver`, `cpu`, `ram`,
`gpus`, `disks`. A mismatch is either an undocumented change on the box or a stale card,
and both are findings. A missing GPU or a shrunk disk list is a hardware finding, not a
documentation one; `nvidia_pci_gpus` says whether an NVIDIA card left the PCI bus or only
the driver lost it, and every entry of `notes` is a finding for the `gpu-server-setup`
skill.

### 5. Stacks against the repo

Compare the compose files mirrored in the host folder with
`docker compose ls --all --format json` on the box. Where the mirror sits is `mirror` in
`fleet.yaml`: with `box-path` a project whose `ConfigFiles` is
`/srv/vllm/docker-compose.yaml` is mirrored in
`<namespace>/<host>/srv/vllm/docker-compose.yaml`, with `containers` in
`<namespace>/<host>/containers/<stack>/`. A mirrored stack that is not running is **a
question, not a fault**: look for an explicit statement in the README body. A box
reinstalled with some of its stacks deliberately left down says so there; if the body
explains it, it is expected, and if nothing explains it, that is the finding.

### 6. Functional probe

This is the step that actually decides the verdict. Take the ports and stacks from the
README body and call each service the way its clients do:

| Service | Probe |
|---|---|
| vLLM, TEI, Infinity, LiteLLM, llama.cpp, Ollama | `GET /v1/models`, then one real `/v1/embeddings` or `/v1/chat/completions` |
| Whisper, GigaAM | `POST /v1/audio/transcriptions` with a small generated wav |
| exporters | `GET /metrics`; a `401` with `WWW-Authenticate` is the expected answer where basic auth is on |
| reverse proxy | the public URL, expecting the auth gate to answer, not the backend |

An endpoint behind a gateway must be probed through the gateway too: a backend that
answers on the LAN and a gateway that does not is a real outage for users.

### 7. Verdict

| Verdict | Meaning |
|---|---|
| `healthy` | every service answered a real request, no `FAIL`, card matches |
| `warming up` | a service is down only because it is still loading, see below |
| `degraded` | the box serves, but something is wrong (a `WARN`, drift, one dead service out of many) |
| `broken` | a service its users depend on does not answer |
| `unreachable` | ssh did not get through |

Report the verdict, then the evidence, then what you did not check and why.

## Warming up is not an outage

After a power cut a big model takes minutes to load and its port refuses connections the
whole time. One field case took about eleven minutes from container start to the first
answer: 42 checkpoint shards at roughly seven seconds each from a cold page cache, then
engine init and graph capture. Before calling a port dead:

```bash
<ssh> docker logs --tail 20 <container>          # loading progress?
<ssh> docker inspect <container> --format '{{.State.StartedAt}}'
```

A young container whose log shows loading progress is `warming up`. Poll until it answers
or stops progressing, and only then call it broken. If the log has already rotated away
(stacks that cap `max-size`), fall back to container age plus GPU memory climbing in
`nvidia-smi`. `healthcheck.sh` warns when the host booted less than 15 minutes ago for
exactly this reason.

## What "Up" hides

Every one of these has happened in the field; all of them show `Up` in `docker ps`.

| Symptom | What it really is | How to see it |
|---|---|---|
| every model 404s or times out, all at once | containers created before dhcpcd wrote `resolv.conf`, so they have no resolver | `NO EXTERNAL NAMESERVERS` in the container's `/etc/resolv.conf` |
| one model dies with a CUDA error, container stays up | CUDA context death, memory creep on that card | container logs, `nvidia-smi` memory on the card |
| container restart-loops on start | model download timing out, or a torn HF blob | `RestartCount`, logs |
| an embedder answers but is suspiciously slow | it silently fell back to CPU | logs at startup, latency of a probe |
| health endpoint says a model is dead while it serves fine | wrong probe mode in the proxy config | call the model directly, compare |

## Namespace mode

"Check the whole `lab` namespace" means every host in it, not the interesting ones.

1. read `<namespace>/README.md`, take the host list and the topology;
2. drop `status: retired`; report `status: pending` hosts as pending rather than checking them;
3. order the hosts so a `jump` host is checked before what sits behind it: if the jump is
   down, everything behind it is `unreachable` for a reason you already know;
4. run the per-host procedure for each, in parallel where the hosts are independent;
5. never silently drop a host you could not reach, `unreachable` is a verdict;
6. roll up: one line per host with its verdict, then the namespace verdict, which is the
   worst host verdict, then the findings in full.

A namespace pass is cheap on the script and expensive on the functional probes, so probe
what the namespace actually serves rather than every open port.

## Common mistakes

- **Reporting a raw counter as a fault.** A PCIe AER or ECC counter means nothing without
  a rate and a comparison. In one field case a card sat at 725 corrected errors while two
  of its siblings sat at exactly zero; an hour later that card was past 940. The finding
  is that it *keeps growing* while fatal stays at zero, not the number itself, which is
  stale the moment you write it down. Sample twice, compare siblings, then judge.
- **Trusting a tool or a subagent that reports an alarm.** Reproduce it yourself before
  putting it in the report, and say what you measured.
- **Naming a cause you have not isolated.** A lane that fails a quarter of the time is a
  measurement; "it is DNS" is a claim. Change one variable at a time (plain HTTP against
  TLS, an IP literal against a name, the sibling host as the control) until only one
  explanation survives. A wrong cause in the report sends the user to fix the wrong thing.
- **Treating leftover containers as an outage.** A one-shot with restart policy `no` that
  exited 0 months ago is litter; a container with `unless-stopped` that is down is a
  fault. `healthcheck.sh` separates them, do not re-merge them in the report.
- **Calling a stopped stack an outage** without reading the README body first.
- **Stopping at `docker ps`.** It is the weakest signal on this list.
- **Fixing things during a health check.** Report and ask.
- **Declaring a namespace healthy when one host was unreachable.** It is `degraded` at best.

## Hand-offs

- driver missing, `nvidia-smi` failing, Docker not seeing the GPU, an Intel card without
  a render node: the `gpu-server-setup` skill, then re-run this one;
- the card is stale or the host was rebuilt: the `server-discovery` skill refreshes it,
  comparing before it writes, then runs `render_index.py`;
- anything you change as a result of a check, mirror in the repository in the same task.
