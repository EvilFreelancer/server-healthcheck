# Authoring & maintaining the `server-healthcheck` skill

Agent guide for working **inside this skill repository**. Read it before editing
`SKILL.md`, `scripts/healthcheck.sh` or any plugin manifest.

> Naming (Russian): the adjective for "agent / agentic" is **«агентный»**, never
> «агентский».

## Repository layout

```
server-healthcheck/
├─ .claude-plugin/plugin.json  .cursor-plugin/plugin.json  .codex-plugin/plugin.json
├─ SKILL.md              # CANONICAL skill: YAML frontmatter + instructions
├─ scripts/healthcheck.sh  # one read-only POSIX pass, PASS/WARN/FAIL/SKIP and an exit code
├─ tests/                # the GPU section against fake sysfs trees
├─ README.md  AGENTS.md  LICENSE
```

## Editing rules

- **Read-only, always.** Neither the script nor the procedure may change a host. The
  only requests the skill sends are the ones a service is built to answer.
- **`healthcheck.sh` is POSIX sh** and runs on busybox and Synology: every probe is
  optional, a missing tool is a `SKIP`, `sudo` only as `sudo -n`, no `set -e` (it
  collects failures), exit 1 on any `FAIL`. sysfs is read through `HEALTHCHECK_SYSFS`
  so the tests can use fake trees; a new sysfs probe goes through it too and gets a
  test.
- **A verdict needs evidence.** A new check reports what it measured; a counter is
  judged by its rate and against its siblings, never on its own.
- **Lessons stay, names go.** A field case that taught a rule is told without the
  hostname, the address or the date of the box it happened on.

After editing run:

```bash
sh -n scripts/healthcheck.sh
python3 -m unittest discover -s tests -v
sh scripts/healthcheck.sh        # on this machine, read the output
```

## No personal data

The skill is public and serves any fleet. Examples, fixtures and tests use neutral
values only: hosts `node1`, `node2`, a namespace `lab`, the login `ops`, private ranges
(`10.0.0.0/24`) and the documentation ranges (`192.0.2.0/24`, `198.51.100.0/24`,
`203.0.113.0/24`), `example.org`. Never copy a real hostname, login, address, domain,
password or incident date from a harness into this repository; the lessons of an
incident stay, its names go. Before every commit:

```bash
grep -rnE '[0-9]{1,3}(\.[0-9]{1,3}){3}' --include='*.md' --include='*.py' --include='*.sh' . | grep -vE '\b(10|127)\.|192\.0\.2\.|198\.51\.100\.|203\.0\.113\.|0\.0\.0\.0'
```

prints nothing but version numbers.

## Keeping metadata in sync

When you change the description or bump the version, update it in **all** of:

- `SKILL.md` frontmatter (`metadata.version`, `description`)
- `.claude-plugin/plugin.json`
- `.cursor-plugin/plugin.json`
- `.codex-plugin/plugin.json` (both top-level and the `interface` block)
- `README.md`

Keep the `name` identical everywhere: `server-healthcheck`. The Claude manifest must not carry a
`category` key, the plugin schema rejects it. Keep the `SKILL.md` frontmatter strict YAML
(`description` as a folded `>` block), otherwise some agents load the skill without its
description.

## The set of fleet skills

`server-discovery`, `server-onboarding`, `server-healthcheck` and `gpu-server-setup` are
released separately but work as one set inside a harness, installed side by side in
`.agents/skills/`. The contract between them:

- `server-discovery` owns every script that reads a box into a card or validates the
  fleet, and the conventions in its `references/`; the other skills call its scripts by
  `.agents/skills/server-discovery/scripts/<script>` and link its references by
  `../server-discovery/references/<file>`;
- a renamed script, a changed command line, a new JSON key of `discover.py` or a new
  `fleet.yaml` key is a change in every skill that mentions it, released together;
- hand-offs name the other skill by its `name`, never by a path of one harness.

When the set is published in the [rpa-skills](https://github.com/EvilFreelancer/rpa-skills)
catalog, mirror every version and description change there as its `AGENTS.md` says.
