# server-healthcheck

An agent skill that answers "is this server, or this whole namespace, actually healthy"
for a fleet harness repository, read-only. It never repairs: it diagnoses, reports a
verdict with the evidence, and asks.

It is one of four skills of a universal devops harness:

| Skill | Does |
|---|---|
| [server-discovery](https://github.com/EvilFreelancer/server-discovery) | read a box, refresh its card, validate the fleet, regenerate the index and the map |
| [server-onboarding](https://github.com/EvilFreelancer/server-onboarding) | add a new box: placement, card, README, mirrored configs, Topology, GPU hand-off |
| **server-healthcheck** | is a box or a namespace actually healthy, read-only |
| [gpu-server-setup](https://github.com/EvilFreelancer/gpu-server-setup) | NVIDIA or Intel Arc driver, Docker GPU access, serving stacks, power caps |

It uses `discover.py` of `server-discovery` for the drift check, so install both.

## The principle

`Up` is not healthy. A host is healthy when the box is sound, every service it is
supposed to run answers a real request, and the live facts still match its card. The
verdict is one of `healthy`, `warming up`, `degraded`, `broken`, `unreachable`, and a
namespace is as healthy as its worst host.

## What it does

- **`scripts/healthcheck.sh`** - one POSIX pass over the box with `PASS`, `WARN`,
  `FAIL`, `SKIP` lines and an exit code: boot history and unclean shutdowns, clock sync,
  failed units, disk usage and read-only remounts, kernel I/O errors, OOM kills, container
  states, restart counts and resolvers, published ports without a listener, NVIDIA GPUs
  against the PCI bus with ECC and Xid, Intel discrete GPUs without a driver or a render
  node, PCIe AER of every GPU judged by its rate. Runs on Debian, Ubuntu, busybox
  (OpenWrt) and Synology DSM.
- **Card drift** - the live facts of `discover.py` against the frontmatter card.
- **Stacks against the mirror** - what `docker compose ls` runs against what the
  repository mirrors, read with the README body before calling anything an outage.
- **Functional probes** - every service is called the way its clients call it
  (`/v1/models`, a one-token completion, a short transcription, `/metrics`), through the
  gateway when users reach it that way.
- **Warm-up rule** - a model still loading after a power cut is `warming up`, not dead.

## Install

Inside a harness repository, as git submodules next to each other:

```bash
git submodule add https://github.com/EvilFreelancer/server-discovery.git .agents/skills/server-discovery
git submodule add https://github.com/EvilFreelancer/server-healthcheck.git .agents/skills/server-healthcheck
ln -s ../../.agents/skills/server-healthcheck .claude/skills/server-healthcheck   # Claude Code
```

As plain skill folders, put both repositories side by side in one skill root; the
directory names must match the `name` fields.

## Usage

- "Is node1 OK after the power cut?"
- "Check the whole lab namespace."
- "The embeddings endpoint looks up but answers nothing, what is wrong?"

```bash
ssh node1 sh -s < scripts/healthcheck.sh
python3 -m unittest discover -s tests -v
```

## License

MIT © Pavel Rykov.
