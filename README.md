# pstack-project

Project-local install, update, and uninstall of [pstack](https://github.com/cursor/plugins/tree/main/pstack) (Lauren Tan / @poteto) for **Claude Code** and **Grok Build**.

GitHub gists cannot live under an organization, so this public repo is the org copy. A public gist of the same script is also published from the maintainer account.

## Use

From the repository you want pstack in:

```bash
curl -fsSL https://raw.githubusercontent.com/ecociel/pstack-install/main/pstack-project.sh -o pstack-project.sh
chmod +x pstack-project.sh
./pstack-project.sh install
```

```bash
./pstack-project.sh update
./pstack-project.sh uninstall
./pstack-project.sh uninstall --purge-config
```

## What it does

- Creates `.agents/skills/`, `.claude/skills/`, and `.grok/skills/` if missing.
- Vendors known pstack skills (including `principle-*`) into `.agents/skills/` and links them into the Claude and Grok skill dirs.
- Does **not** overwrite files or skill folders it does not own.
- Does **not** touch generated verification skills (`verify-*` other than upstream `verify-commands`).
- Writes model config only when those files are missing.
- Patches `CLAUDE.md` and `AGENTS.md` inside a marked `pstack:managed` section only.

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

Playbooks and principles remain Lauren Tan's.
