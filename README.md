# pstack-project

Project-local install, update, and uninstall of [pstack](https://github.com/cursor/plugins/tree/main/pstack) (Lauren Tan / @poteto) for **Claude Code** and **Grok Build**.

## Caveat

Made with Grok 4.7 and and adversarial review by Opus 5.5 but not battle tested.

## Use

From the **git toplevel** of the repository you want pstack in:

```bash
curl -fsSL https://raw.githubusercontent.com/ecociel/pstack-install/main/pstack-project.sh -o pstack-project.sh
chmod +x pstack-project.sh
./pstack-project.sh install
```

```bash
./pstack-project.sh update
./pstack-project.sh uninstall
./pstack-project.sh uninstall --purge-config
./pstack-project.sh install --dry-run
```

`--force` allows a cwd that is not the git toplevel. The script refuses `$HOME` and `/` unless `--force` is set (still refuses `/`).

## What it does

- Creates `.agents/skills/`, `.claude/skills/`, and `.grok/skills/` if missing.
- Vendors known pstack skills (including `principle-*`) into `.agents/skills/` and links them into the Claude and Grok skill dirs with **relative** links.
- Owns a path only when the skill name is on the pstack list **and** the directory stamp is exactly `pstack-managed-id: ecociel-pstack-project`.
- Removes a symlink only when it resolves to this repo's `.agents/skills/<name>` and that folder is stamped.
- Does not touch generated verification skills (`verify-*` other than upstream `verify-commands`).
- Writes model config only when those files are missing.
- Patches `CLAUDE.md`, `AGENTS.md`, and `.gitignore` only inside exact-line `pstack:managed` markers. Unbalanced markers are an error; the file is not changed.
- Adds `.pstack/` to `.gitignore`. The upstream clone stays out of your project history.
- `--dry-run` prints destructive actions and writes nothing.

Do not keep project notes inside a vendored skill folder under a pstack name. A renamed copy (`my-why`) is left alone even if it still has a stamp.

## Per-repo vs a global install

This script never writes under `$HOME`. A global install you already have stays on disk:

```
~/.claude/skills/poteto-mode
~/.grok/skills/poteto-mode
~/.agents/skills/poteto-mode
~/.claude/pstack-models.md
~/.agents/pstack-models.md
~/.grok/rules/pstack-models.md
~/.grok/pstack-models.toml
~/.cursor/rules/pstack-models.mdc
```

It also does not uninstall or upgrade those files. The two copies then compete.

**Skills.** Claude Code and Grok Build load user skills and project skills. After a per-repo install you have two `poteto-mode` trees (and two of every other pstack name). The project copy is the one this repo can version and ship to remotes. The global copy is still visible in a local session. If they differ (different upstream, different `/setup-pstack` edits), the agent may pick either. Safe patterns: keep the global skills and treat the repo as the override; or remove the overlapping names from `~/.claude/skills` and `~/.grok/skills` and leave only the project links. Do not point a project skill folder at your home skills directory — the installer refuses a skill path that resolves outside the repo.

**Model sheets.** Official and ported pstack still look in the home directory unless the skill text or `CLAUDE.md` / `AGENTS.md` says otherwise. This installer writes project sheets and a managed instruction block that says the project file wins. That block is the interference: a local session that used `~/.claude/pstack-models.md` (Opus / Sonnet pins, a Cursor `.mdc`, a Grok toml) should now follow `.agents/pstack-models.md` in this repo, which defaults to `inherit-parent`. The home sheet is not deleted. If the agent ignores the project block, you get the global pins again — including slugs that a remote or the other harness cannot spawn. Edit the project sheet, or delete the managed section from `CLAUDE.md` / `AGENTS.md` if you want the global sheet back.

**Remotes.** Claude Code cloud, Codespaces, and a fresh Grok checkout do not see `$HOME`. Only the committed project files apply there. A global-only install does nothing in those environments; a per-repo install is what makes pstack show up.

**Uninstall.** `./pstack-project.sh uninstall` removes owned project skills and the managed instruction section. It does not restore or remove the global install. After uninstall, local sessions fall back to `~/.claude/skills` and the home model sheet again.

Keep a global install if you want pstack in repos that do not vendor it. Add this per-repo install when the repo must carry its own skills and model policy, especially onto remotes.

## Model config

After install, edit:

```
.agents/pstack-models.md
```

Grok copies (written once, then left alone):

```
.grok/rules/pstack-models.md
.grok/pstack-models.toml
```

The generated sheets use `inherit-parent` so a remote session keeps the parent model. Each sheet also contains a **commented** late-September 2026 pin for **that host only**:

- `.agents/pstack-models.md` — Claude only (`claude-sonnet-5` mechanical, `claude-opus-5-5` judgment)
- `.grok/rules/pstack-models.md` and `.grok/pstack-models.toml` — Grok only (`grok-4.7`)

Do not mix vendors in one file. Uncomment a pin only after that host lists the slugs. Pick the parent session model first, then override only the roles that should differ.

## Upstream

Default source is `https://github.com/mdsmithaustin/pstack.git` (portable skill tree). Override with:

```bash
PSTACK_REPO=https://github.com/tommy-ca/pstack.git PSTACK_REF=main ./pstack-project.sh install
```

A bad `PSTACK_REF` is an error. Changing `PSTACK_REPO` on update retargets the existing `.pstack/src` remote.

Playbooks and principles remain Lauren Tan's. This repository is MIT-licensed; that license covers the installer, not upstream pstack content.

## Tests

```bash
bash tests/regression.sh
```
