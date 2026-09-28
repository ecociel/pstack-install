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

The generated sheet uses `inherit-parent` so a remote Claude or Grok session keeps working with the parent model. You will probably want to replace those values with slugs from `grok models` or Claude Code's Agent model list.

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
