#!/usr/bin/env bash
# pstack-project.sh — install, update, or uninstall pstack in the current directory
# for Claude Code and Grok Build (project scope, remote-safe).
#
# Usage:
#   ./pstack-project.sh install [--force] [--dry-run]
#   ./pstack-project.sh update [--force] [--dry-run]
#   ./pstack-project.sh uninstall [--purge-config] [--force] [--dry-run]
#
# Env:
#   PSTACK_REPO   git URL (default: https://github.com/mdsmithaustin/pstack.git)
#   PSTACK_REF    branch/tag/commit (default: main)
#   PSTACK_SKILLS subdirectory inside the repo that holds skills (default: skills)
#
# pstack playbooks © Lauren Tan (@poteto). This installer only vendors and wires them.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: pstack-project.sh <install|update|uninstall> [options]

install     Vendor pstack skills into this repo and write model config if missing
update      Refresh owned pstack skills from upstream; keep model config and verify-*
uninstall   Remove owned pstack files only; keep verify-* and (unless --purge-config) model config

Options:
  --force          Allow a cwd that is not the git toplevel
  --dry-run        Print destructive actions; change nothing
  --purge-config   On uninstall, delete managed model sheets
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

ACTION=""
PURGE_CONFIG=0
FORCE=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    install|update|uninstall)
      [[ -z "$ACTION" ]] || die "multiple actions"
      ACTION="$arg"
      ;;
    --purge-config) PURGE_CONFIG=1 ;;
    --force) FORCE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help|help) usage; exit 0 ;;
    *) usage; die "unknown argument: $arg" ;;
  esac
done
[[ -n "$ACTION" ]] || { usage; exit 1; }

ROOT="$(pwd)"
PSTACK_REPO="${PSTACK_REPO:-https://github.com/mdsmithaustin/pstack.git}"
PSTACK_REF="${PSTACK_REF:-main}"
PSTACK_SKILLS="${PSTACK_SKILLS:-skills}"

MANAGED_ID="ecociel-pstack-project"
MARKER_BEGIN="<!-- pstack:managed:begin -->"
MARKER_END="<!-- pstack:managed:end -->"
GROK_MARKER_BEGIN="# pstack:managed:begin"
GROK_MARKER_END="# pstack:managed:end"
OWNED_STAMP=".pstack-owned"

PSTACK_DIR="${ROOT}/.pstack"
SRC_DIR="${PSTACK_DIR}/src"
MANIFEST="${PSTACK_DIR}/manifest"
STATE="${PSTACK_DIR}/state"

AGENTS_SKILLS="${ROOT}/.agents/skills"
CLAUDE_SKILLS="${ROOT}/.claude/skills"
GROK_SKILLS="${ROOT}/.grok/skills"
MODELS_MD="${ROOT}/.agents/pstack-models.md"
MODELS_GROK_MD="${ROOT}/.grok/rules/pstack-models.md"
MODELS_GROK_TOML="${ROOT}/.grok/pstack-models.toml"
GROK_RULE="${ROOT}/.grok/rules/pstack.md"
CLAUDE_MD="${ROOT}/CLAUDE.md"
AGENTS_MD="${ROOT}/AGENTS.md"
GITIGNORE="${ROOT}/.gitignore"

PSTACK_SKILLS_ALLOW='
architect
arena
automate-me
blast-radius
bro
create-verification-skill
documentation-impact
figure-it-out
how
interrogate
maintain-verification-skill
make-bot-ui
no-comments
poteto-mode
poteto-tdd
poteto-teach
pstack-harness
recall
reflect
runtime-probes
setup-pstack
show-me-your-work
spec-probes
swarm
tdd
teach
technical-writing
typescript-best-practices
unslop
verify-commands
why
'

relpath() {
  local path="$1"
  path="${path#"$ROOT"/}"
  path="${path#"$ROOT"}"
  printf '%s\n' "$path"
}

abspath() {
  python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

exists_any() {
  [[ -e "$1" || -L "$1" ]]
}

is_inside_root() {
  local resolved="$1"
  local root_res="$2"
  [[ "$resolved" == "$root_res" || "$resolved" == "$root_res"/* ]]
}

assert_under_root() {
  local path="$1"
  exists_any "$path" || return 0
  local resolved root_res
  resolved="$(abspath "$path")"
  root_res="$(abspath "$ROOT")"
  is_inside_root "$resolved" "$root_res" \
    || die "refusing path outside the project: $path -> $resolved"
}

log() { printf '%s\n' "$*"; }

run_rm() {
  # Usage: run_rm [-f|-rf] path
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'dry-run rm %s\n' "$*"
    return 0
  fi
  rm "$@"
}

is_verify_skill() {
  local name="$1"
  [[ "$name" == verify-* && "$name" != verify-commands ]]
}

is_allowlisted_skill() {
  local name="$1"
  if is_verify_skill "$name"; then
    return 1
  fi
  if [[ "$name" == principle-* ]]; then
    return 0
  fi
  printf '%s\n' "$PSTACK_SKILLS_ALLOW" | grep -Fxq "$name"
}

stamp_matches() {
  local dir="$1"
  [[ -f "$dir/$OWNED_STAMP" ]] || return 1
  grep -Fxq "pstack-managed-id: ${MANAGED_ID}" "$dir/$OWNED_STAMP"
}

is_managed_file() {
  local path="$1"
  [[ -f "$path" || -L "$path" ]] || return 1
  grep -Fxq "pstack-managed-id: ${MANAGED_ID}" "$path" \
    || grep -Fxq "# pstack-managed-id: ${MANAGED_ID}" "$path"
}

canonical_agents_skill() {
  printf '%s\n' "${AGENTS_SKILLS}/$1"
}

is_owned_symlink() {
  local path="$1"
  local name
  name="$(basename "$path")"
  [[ -L "$path" ]] || return 1
  is_allowlisted_skill "$name" || return 1
  is_verify_skill "$name" && return 1
  local want resolved
  want="$(abspath "$(canonical_agents_skill "$name")")"
  resolved="$(abspath "$path")"
  [[ "$resolved" == "$want" ]] || return 1
  stamp_matches "$(canonical_agents_skill "$name")"
}

is_owned_skill_dir() {
  local path="$1"
  local name
  name="$(basename "$path")"
  [[ -d "$path" && ! -L "$path" ]] || return 1
  is_allowlisted_skill "$name" || return 1
  stamp_matches "$path"
}

ensure_dir() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    [[ -d "$1" ]] || printf 'dry-run mkdir %s\n' "$(relpath "$1")"
    return 0
  fi
  mkdir -p "$1"
}

record() {
  local rel="$1"
  rel="${rel#./}"
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  ensure_dir "$(dirname "$MANIFEST")"
  touch "$MANIFEST"
  grep -Fqx "$rel" "$MANIFEST" 2>/dev/null || printf '%s\n' "$rel" >>"$MANIFEST"
}

write_through() {
  local dest="$1"
  local tmp="$2"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'dry-run write %s\n' "$(relpath "$dest")"
    rm -f "$tmp"
    return 0
  fi
  if exists_any "$dest"; then
    cat "$tmp" >"$dest"
  else
    ensure_dir "$(dirname "$dest")"
    cat "$tmp" >"$dest"
    chmod 644 "$dest" 2>/dev/null || true
  fi
  rm -f "$tmp"
}

write_owned_file() {
  local dest="$1"
  local mode="${2:-skip-if-foreign}"
  local tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  if exists_any "$dest"; then
    if is_managed_file "$dest" || [[ "$mode" == "force-owned" ]]; then
      :
    elif [[ "$mode" == "skip-if-exists" ]]; then
      rm -f "$tmp"
      log "keep  $(relpath "$dest") (already exists; not overwritten)"
      return 0
    else
      rm -f "$tmp"
      log "skip  $(relpath "$dest") (exists and is not a pstack-managed file)"
      return 0
    fi
  fi
  write_through "$dest" "$tmp"
  record "$(relpath "$dest")"
  log "write $(relpath "$dest")"
}

stamp_dir() {
  local dest="$1"
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  printf 'pstack-managed-id: %s\n' "$MANAGED_ID" >"${dest}/${OWNED_STAMP}"
  record "$(relpath "${dest}/${OWNED_STAMP}")"
}

guard_cwd() {
  local root_res home_res
  root_res="$(abspath "$ROOT")"
  home_res="$(abspath "${HOME:-/no-such-home}")"
  if [[ "$root_res" == "/" ]]; then
    die "refusing to run in /"
  fi
  if [[ "$root_res" == "$home_res" && "$FORCE" -eq 0 ]]; then
    die "refusing to run in \$HOME (pass --force to override)"
  fi
  if [[ "$FORCE" -eq 0 ]]; then
    command -v git >/dev/null 2>&1 || die "git is required"
    local top
    top="$(git rev-parse --show-toplevel 2>/dev/null)" \
      || die "cwd is not a git repository (pass --force to override)"
    top="$(abspath "$top")"
    [[ "$top" == "$root_res" ]] \
      || die "cwd is not the git toplevel ($top); pass --force to override"
  fi
}

guard_skill_layout() {
  local root_res
  root_res="$(abspath "$ROOT")"
  local -a resolved=()
  local -a labels=()
  local p r
  for p in "$AGENTS_SKILLS" "$CLAUDE_SKILLS" "$GROK_SKILLS"; do
    exists_any "$p" || continue
    r="$(abspath "$p")"
    is_inside_root "$r" "$root_res" \
      || die "$(relpath "$p") resolves outside the project: $r"
    resolved+=("$r")
    labels+=("$(relpath "$p")")
  done
  local i j
  for ((i = 0; i < ${#resolved[@]}; i++)); do
    for ((j = i + 1; j < ${#resolved[@]}; j++)); do
      if [[ "${resolved[$i]}" == "${resolved[$j]}" ]]; then
        log "note  ${labels[$i]} and ${labels[$j]} resolve to the same folder; links between them will be skipped"
      fi
    done
  done
}

same_resolved() {
  local a="$1" b="$2"
  exists_any "$a" || return 1
  exists_any "$b" || return 1
  [[ "$(abspath "$a")" == "$(abspath "$b")" ]]
}

relative_skill_link() {
  local dest_dir="$1"
  local name="$2"
  python3 -c '
import os, sys
dest_dir, name, target = sys.argv[1], sys.argv[2], sys.argv[3]
print(os.path.relpath(os.path.join(target, name), dest_dir))
' "$dest_dir" "$name" "$AGENTS_SKILLS"
}

install_skill_dir() {
  local src="$1"
  local dest="$2"
  local name
  name="$(basename "$dest")"

  if is_verify_skill "$name"; then
    log "keep  $(relpath "$dest") (generated verification skill)"
    return 0
  fi

  if exists_any "$dest"; then
    if [[ -L "$dest" ]]; then
      if is_owned_symlink "$dest"; then
        run_rm -f "$dest"
      else
        log "skip  $(relpath "$dest") (symlink not owned by this installer)"
        return 0
      fi
    elif is_owned_skill_dir "$dest"; then
      :
    else
      log "skip  $(relpath "$dest") (exists and is not a pstack-owned skill)"
      return 0
    fi
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "dry-run skill $(relpath "$dest")"
    return 0
  fi

  ensure_dir "$dest"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --exclude "$OWNED_STAMP" --exclude "MY-NOTES.md" "$src"/ "$dest"/
  else
    cp -R "$src"/. "$dest"/
  fi
  stamp_dir "$dest"
  record "$(relpath "$dest")"
  log "skill $(relpath "$dest")"
}

link_or_copy_skill() {
  local src="$1"
  local dest="$2"
  local name
  name="$(basename "$dest")"
  if is_verify_skill "$name"; then
    return 0
  fi
  if same_resolved "$(dirname "$dest")" "$(dirname "$src")"; then
    log "skip  $(relpath "$dest") (same folder as $(relpath "$src"))"
    return 0
  fi
  if exists_any "$dest"; then
    if [[ -L "$dest" ]]; then
      if is_owned_symlink "$dest"; then
        run_rm -f "$dest"
      else
        log "skip  $(relpath "$dest") (symlink not owned by this installer)"
        return 0
      fi
    elif is_owned_skill_dir "$dest"; then
      run_rm -rf "$dest"
    else
      log "skip  $(relpath "$dest") (exists and is not a pstack-owned skill)"
      return 0
    fi
  fi
  ensure_dir "$(dirname "$dest")"
  local rel
  rel="$(relative_skill_link "$(dirname "$dest")" "$name")"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "dry-run link $(relpath "$dest") -> $rel"
    return 0
  fi
  if ln -s "$rel" "$dest" 2>/dev/null; then
    record "$(relpath "$dest")"
    log "link  $(relpath "$dest") -> $rel"
  else
    install_skill_dir "$src" "$dest"
  fi
}

fetch_upstream() {
  command -v git >/dev/null 2>&1 || die "git is required"
  ensure_dir "$PSTACK_DIR"
  if [[ -d "${SRC_DIR}/.git" ]]; then
    git -C "$SRC_DIR" remote set-url origin "$PSTACK_REPO"
    git -C "$SRC_DIR" fetch --depth 1 origin "$PSTACK_REF" \
      || die "cannot fetch $PSTACK_REF from $PSTACK_REPO"
    git -C "$SRC_DIR" checkout --force --quiet FETCH_HEAD \
      || die "cannot checkout $PSTACK_REF"
  else
    if exists_any "$SRC_DIR"; then
      die "$SRC_DIR exists and is not a git clone of pstack"
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "dry-run clone $PSTACK_REPO@$PSTACK_REF"
      return 0
    fi
    if ! git clone --depth 1 --branch "$PSTACK_REF" "$PSTACK_REPO" "$SRC_DIR" 2>/dev/null; then
      git clone --depth 1 "$PSTACK_REPO" "$SRC_DIR" \
        || die "cannot clone $PSTACK_REPO"
      git -C "$SRC_DIR" fetch --depth 1 origin "$PSTACK_REF" \
        || die "cannot fetch $PSTACK_REF from $PSTACK_REPO"
      git -C "$SRC_DIR" checkout --force --quiet FETCH_HEAD \
        || die "cannot checkout $PSTACK_REF"
    fi
  fi
  local rev
  rev="$(git -C "$SRC_DIR" rev-parse HEAD)"
  printf '%s\n' "$rev" >"${PSTACK_DIR}/revision"
  log "source $PSTACK_REPO@$PSTACK_REF ($rev)"
}

skills_src() {
  local candidate="${SRC_DIR}/${PSTACK_SKILLS}"
  if [[ -d "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  if [[ -d "${SRC_DIR}/plugins/pstack/skills" ]]; then
    printf '%s\n' "${SRC_DIR}/plugins/pstack/skills"
    return 0
  fi
  die "no skills directory in $PSTACK_REPO (looked at $PSTACK_SKILLS and plugins/pstack/skills)"
}

install_skills() {
  local src_root skill src dest
  src_root="$(skills_src)"
  ensure_dir "$AGENTS_SKILLS"
  ensure_dir "$CLAUDE_SKILLS"
  ensure_dir "$GROK_SKILLS"
  record ".agents/skills"
  record ".claude/skills"
  record ".grok/skills"

  local -A seen=()
  shopt -s nullglob
  for src in "$src_root"/*/; do
    skill="$(basename "$src")"
    if is_verify_skill "$skill"; then
      continue
    fi
    if ! is_allowlisted_skill "$skill"; then
      log "skip  upstream skill $skill (not a known pstack skill)"
      continue
    fi
    seen["$skill"]=1
    dest="${AGENTS_SKILLS}/${skill}"
    install_skill_dir "$src" "$dest"
    link_or_copy_skill "$dest" "${CLAUDE_SKILLS}/${skill}"
    link_or_copy_skill "$dest" "${GROK_SKILLS}/${skill}"
  done
  # Drop owned skills that disappeared upstream.
  for dest in "$AGENTS_SKILLS"/*; do
    exists_any "$dest" || continue
    skill="$(basename "$dest")"
    [[ -n "${seen[$skill]:-}" ]] && continue
    if is_owned_skill_dir "$dest" || is_owned_symlink "$dest"; then
      log "drop  $(relpath "$dest") (gone upstream)"
      if [[ -L "$dest" ]]; then
        run_rm -f "$dest"
      else
        run_rm -rf "$dest"
      fi
    fi
  done
  shopt -u nullglob
}

models_md_body() {
  cat <<'EOF'
# pstack-managed: true
# pstack-managed-id: ecociel-pstack-project
# pstack model configuration (project). One line per role.
#
# How to think about this file
# ----------------------------
# 1. Pick the parent session model first (Claude Code `/model`, Grok TUI
#    model picker, or `grok -m`). That is the top-level choice. It sets
#    cost, latency, and the default brain for anything not pinned below.
# 2. inherit-parent / auto means the child omits its model field and
#    follows that parent. Use this on remotes and whenever you only have
#    one usable model. A missing line falls back to the skill default.
# 3. Pin a role only when it should differ from the parent: cheaper /
#    faster for mechanical work, stronger for judgment, or a mixed panel.
# 4. Write only slugs the current host will spawn. Check `grok models`
#    or Claude Code's Agent model list. Cursor slugs
#    (grok-4.7-xhigh-fast, claude-opus-5-5-max) belong in Cursor, not here.
# 5. A comma-separated value is a panel: one child per entry. List
#    length is fan-out. Repeat a slug only if you want two of the same.
#
# Role families (Lauren's split, still the right shape)
# -----------------------------------------------------
# Mechanical / throughput  feature, refactoring, bug-fix, perf, hillclimb,
#                          how explorer, why investigators, swarm workers
# Judgment / prose         judgment and prose, hardest tasks, how explainer,
#                          why synthesizer, reflect judgment
# Mixed panels             how critics, arena, architect, interrogate
#
# budget: high
#
# Active map: inherit-parent so Claude Code and Grok Build remotes work
# with whatever the parent session already selected.

feature, refactoring: inherit-parent
bug-fix: inherit-parent
perf-issue: inherit-parent
hillclimb: inherit-parent
judgment and prose: inherit-parent
hardest tasks: inherit-parent
how explorer: inherit-parent
how explainer: inherit-parent
how critics: inherit-parent
why investigators: inherit-parent
why synthesizer: inherit-parent
reflect tooling: inherit-parent
reflect judgment, divergent, synthesizer: inherit-parent
arena runners: inherit-parent
arena cross-judge pool: inherit-parent
swarm workers: inherit-parent
architect runners: inherit-parent
interrogate reviewers: inherit-parent

# --- late September 2026 pinned map (commented) ---
# Opus 5.5 (2026-09-22, id claude-opus-5-5, Claude Code alias `opus`)
# and Grok 4.7 (2026-09-21, id grok-4.7) just landed. Official pstack
# still sends mechanical work to Grok and judgment / hardest / prose
# to Opus. Uncomment this block and comment out the inherit-parent
# lines above only after `grok models` / Claude Agent lists these slugs.
# On Claude Code, `opus` is enough if it resolves to 5.5 (v2.1.280+).
# On a Grok-only parent, drop the opus lines or the spawn will reject them.
#
# feature, refactoring: grok-4.7
# bug-fix: grok-4.7
# perf-issue: grok-4.7
# hillclimb: grok-4.7
# judgment and prose: claude-opus-5-5
# hardest tasks: claude-opus-5-5
# how explorer: grok-4.7
# how explainer: claude-opus-5-5
# how critics: claude-opus-5-5, grok-4.7
# why investigators: grok-4.7
# why synthesizer: claude-opus-5-5
# reflect tooling: grok-4.7
# reflect judgment, divergent, synthesizer: claude-opus-5-5
# arena runners: claude-opus-5-5, grok-4.7
# arena cross-judge pool: claude-opus-5-5, grok-4.7
# swarm workers: grok-4.7
# architect runners: claude-opus-5-5, grok-4.7
# interrogate reviewers: claude-opus-5-5, grok-4.7
EOF
}

models_toml_body() {
  cat <<'EOF'
# pstack-managed: true
# pstack-managed-id: ecociel-pstack-project
# Grok Build overlay (tommy-ca / spawn_subagent). inherit-parent omits
# task.model so the child uses the parent Grok session model.
#
# How to think about this file
# ----------------------------
# 1. The parent `grok` session model is the top-level choice. Set it in
#    the TUI or with `grok -m`. As of late September 2026 that should
#    usually be grok-4.7 (now the Grok Build default).
# 2. This file cannot spawn Claude. Opus 5.5 belongs in
#    .agents/pstack-models.md when the parent is Claude Code, or as a
#    custom [model.*] entry in ~/.grok/config.toml if you have wired an
#    Anthropic endpoint into Grok.
# 3. Pin a key only when that pstack role should not follow the parent.
#    On a grok-4.7 parent, inherit-parent is already the 4.7 map.
# 4. Arrays are panels (one child per entry). Effort is not a model;
#    put it in ~/.grok/roles/pstack:<role>.toml if you use that port.
# 5. Confirm slugs with `grok models` before uncommenting.

feature = "inherit-parent"
refactoring = "inherit-parent"
bug-fix = "inherit-parent"
perf-issue = "inherit-parent"
hillclimb = "inherit-parent"
judgment-and-prose = "inherit-parent"
hardest-tasks = "inherit-parent"
how-explorer = "inherit-parent"
how-explainer = "inherit-parent"
how-critics = ["inherit-parent"]
why-investigators = "inherit-parent"
why-synthesizer = "inherit-parent"
reflect-tooling = "inherit-parent"
arena-runners = ["inherit-parent"]
arena-cross-judge-pool = ["inherit-parent"]
swarm-workers = "inherit-parent"
architect-runners = ["inherit-parent"]
interrogate-reviewers = ["inherit-parent"]

# --- late September 2026 pinned map (commented) ---
# Grok 4.7 landed 2026-09-21 (id grok-4.7). Use this when the parent is
# an older slug and you want every pstack child on 4.7, or when you
# want the pin explicit. Mechanical and judgment are the same slug
# here; raise effort on judgment roles instead of inventing a second
# Grok model. For an Opus/Grok panel, use the markdown sheet under
# Claude Code — do not put claude-opus-5-5 in this toml unless Grok
# lists that slug.
#
# feature = "grok-4.7"
# refactoring = "grok-4.7"
# bug-fix = "grok-4.7"
# perf-issue = "grok-4.7"
# hillclimb = "grok-4.7"
# judgment-and-prose = "grok-4.7"
# hardest-tasks = "grok-4.7"
# how-explorer = "grok-4.7"
# how-explainer = "grok-4.7"
# how-critics = ["grok-4.7"]
# why-investigators = "grok-4.7"
# why-synthesizer = "grok-4.7"
# reflect-tooling = "grok-4.7"
# arena-runners = ["grok-4.7"]
# arena-cross-judge-pool = ["grok-4.7"]
# swarm-workers = "grok-4.7"
# architect-runners = ["grok-4.7"]
# interrogate-reviewers = ["grok-4.7"]
EOF
}

instruction_block() {
  cat <<EOF
${MARKER_BEGIN}
pstack is installed in this repository (project scope).
Skills live in \`.agents/skills/\` and are also linked from \`.claude/skills/\` and \`.grok/skills/\`.
Model config (edit this): \`.agents/pstack-models.md\`
Grok copies: \`.grok/rules/pstack-models.md\` and \`.grok/pstack-models.toml\`
If the project model file exists, use it for every pstack role. Do not prefer
\`~/.claude/pstack-models.md\`, \`~/.agents/pstack-models.md\`, or
\`~/.grok/rules/pstack-models.md\` over the project file.
Use poteto-mode / /poteto-mode for non-trivial engineering work.
Do not delete generated verification skills (\`verify-*\` other than \`verify-commands\`).
${MARKER_END}
EOF
}

grok_rule_body() {
  cat <<EOF
${GROK_MARKER_BEGIN}
# pstack-managed-id: ${MANAGED_ID}

Read \`.grok/rules/pstack-models.md\` and \`.agents/pstack-models.md\` before
any spawn_subagent. Project files win over ~/.grok/rules/pstack-models.md
and ~/.grok/pstack-models.toml.
If a role is inherit-parent or auto, omit the model field.
${GROK_MARKER_END}
EOF
}

count_exact_lines() {
  local file="$1"
  local line="$2"
  grep -Fxc "$line" "$file" 2>/dev/null || true
}

replace_marked_section() {
  local file="$1"
  local begin="$2"
  local end="$3"
  local block="$4"
  local tmp
  tmp="$(mktemp)"
  if ! awk -v begin="$begin" -v end="$end" -v block="$block" '
    $0 == begin {
      if (in_block) { missing_end = 1 }
      print block
      in_block = 1
      found_begin = 1
      next
    }
    $0 == end {
      if (!in_block) { extra_end = 1 }
      in_block = 0
      found_end = 1
      next
    }
    in_block != 1 { print }
    END {
      if (in_block || (found_begin && !found_end)) {
        print "unclosed pstack marker section" > "/dev/stderr"
        exit 2
      }
      if (extra_end) {
        print "unmatched pstack end marker" > "/dev/stderr"
        exit 2
      }
    }
  ' "$file" >"$tmp"; then
    rm -f "$tmp"
    die "refusing to edit $file: pstack markers are unbalanced"
  fi
  write_through "$file" "$tmp"
}

upsert_marked_section() {
  local file="$1"
  local begin="$2"
  local end="$3"
  local block="$4"
  if [[ ! -e "$file" && ! -L "$file" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "dry-run write $(relpath "$file") (created with pstack section)"
      return 0
    fi
    ensure_dir "$(dirname "$file")"
    printf '%s\n' "$block" >"$file"
    chmod 644 "$file" 2>/dev/null || true
    record "$(relpath "$file")"
    log "write $(relpath "$file") (created with pstack section)"
    return 0
  fi
  local begins ends
  begins="$(count_exact_lines "$file" "$begin")"
  ends="$(count_exact_lines "$file" "$end")"
  begins="${begins:-0}"
  ends="${ends:-0}"
  if [[ "$begins" -eq 0 && "$ends" -eq 0 ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "dry-run patch $(relpath "$file") (append pstack section)"
      return 0
    fi
    printf '\n%s\n' "$block" >>"$file"
    log "patch $(relpath "$file") (pstack section appended)"
    return 0
  fi
  if [[ "$begins" -ne "$ends" || "$begins" -eq 0 ]]; then
    die "refusing to edit $file: begin/end pstack markers are unbalanced (begin=$begins end=$ends). Markers must be exact whole lines."
  fi
  replace_marked_section "$file" "$begin" "$end" "$block"
  log "patch $(relpath "$file") (pstack section updated)"
}

strip_marked_section() {
  local file="$1"
  local begin="$2"
  local end="$3"
  exists_any "$file" || return 0
  local begins ends
  begins="$(count_exact_lines "$file" "$begin")"
  ends="$(count_exact_lines "$file" "$end")"
  begins="${begins:-0}"
  ends="${ends:-0}"
  if [[ "$begins" -eq 0 && "$ends" -eq 0 ]]; then
    return 0
  fi
  if [[ "$begins" -ne "$ends" ]]; then
    die "refusing to edit $file: begin/end pstack markers are unbalanced (begin=$begins end=$ends)"
  fi
  replace_marked_section "$file" "$begin" "$end" ""
  log "patch $(relpath "$file") (pstack section removed)"
}

write_models() {
  models_md_body | write_owned_file "$MODELS_MD" skip-if-exists
  models_md_body | write_owned_file "$MODELS_GROK_MD" skip-if-exists
  models_toml_body | write_owned_file "$MODELS_GROK_TOML" skip-if-exists
}

write_instructions() {
  upsert_marked_section "$CLAUDE_MD" "$MARKER_BEGIN" "$MARKER_END" "$(instruction_block)"
  upsert_marked_section "$AGENTS_MD" "$MARKER_BEGIN" "$MARKER_END" "$(instruction_block)"
  grok_rule_body | write_owned_file "$GROK_RULE" skip-if-foreign
}

ensure_gitignore() {
  local block
  block="$(printf '%s\n%s\n%s\n' "$GROK_MARKER_BEGIN" ".pstack/" "$GROK_MARKER_END")"
  upsert_marked_section "$GITIGNORE" "$GROK_MARKER_BEGIN" "$GROK_MARKER_END" "$block"
}

write_state() {
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  ensure_dir "$PSTACK_DIR"
  cat >"$STATE" <<EOF
repo=${PSTACK_REPO}
ref=${PSTACK_REF}
revision=$(cat "${PSTACK_DIR}/revision" 2>/dev/null || echo unknown)
installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  record ".pstack/state"
  record ".pstack/revision"
  record ".pstack/manifest"
  record ".pstack/src"
}

print_model_notice() {
  cat <<EOF

Model config (you will probably want to adjust this):
  ${MODELS_MD}

Grok-specific copies (kept in sync only on first write; later edits stay):
  ${MODELS_GROK_MD}
  ${MODELS_GROK_TOML}

The generated sheet uses inherit-parent so Claude Code and Grok Build remotes
work with whatever model the parent session already has. Each file includes a
commented late-September 2026 pin (grok-4.7 / claude-opus-5-5). Existing model
files are not overwritten; copy the comments from a fresh install or from
this script if you already have a sheet.
EOF
}

remove_owned_skill_entry() {
  local path="$1"
  local name
  name="$(basename "$path")"
  if is_verify_skill "$name"; then
    log "keep  $(relpath "$path") (generated verification skill)"
    return 0
  fi
  if [[ -L "$path" ]]; then
    if is_owned_symlink "$path"; then
      run_rm -f "$path"
      log "rm    $(relpath "$path")"
    else
      log "keep  $(relpath "$path") (symlink not owned)"
    fi
    return 0
  fi
  if is_owned_skill_dir "$path"; then
    run_rm -rf "$path"
    log "rm    $(relpath "$path")"
    return 0
  fi
  log "keep  $(relpath "$path")"
}

uninstall() {
  strip_marked_section "$CLAUDE_MD" "$MARKER_BEGIN" "$MARKER_END"
  strip_marked_section "$AGENTS_MD" "$MARKER_BEGIN" "$MARKER_END"
  strip_marked_section "$GITIGNORE" "$GROK_MARKER_BEGIN" "$GROK_MARKER_END"

  local base path
  for base in "$AGENTS_SKILLS" "$CLAUDE_SKILLS" "$GROK_SKILLS"; do
    [[ -d "$base" && ! -L "$base" ]] || continue
    assert_under_root "$base"
    shopt -s nullglob
    for path in "$base"/*; do
      remove_owned_skill_entry "$path"
    done
    shopt -u nullglob
  done

  if [[ "$PURGE_CONFIG" -eq 1 ]]; then
    local full
    for full in "$MODELS_MD" "$MODELS_GROK_MD" "$MODELS_GROK_TOML" "$GROK_RULE"; do
      if exists_any "$full" && is_managed_file "$full"; then
        run_rm -f "$full"
        log "rm    $(relpath "$full")"
      elif exists_any "$full"; then
        log "skip  $(relpath "$full") (not pstack-managed; not deleted)"
      fi
    done
  else
    log "keep  model config (pass --purge-config to delete managed sheets)"
  fi

  if [[ -d "$PSTACK_DIR" && ! -L "$PSTACK_DIR" ]]; then
    assert_under_root "$PSTACK_DIR"
    local child
    for child in src manifest state revision; do
      if exists_any "${PSTACK_DIR}/${child}"; then
        if [[ -d "${PSTACK_DIR}/${child}" && ! -L "${PSTACK_DIR}/${child}" ]]; then
          run_rm -rf "${PSTACK_DIR}/${child}"
        else
          run_rm -f "${PSTACK_DIR}/${child}"
        fi
        log "rm    .pstack/${child}"
      fi
    done
    if [[ "$DRY_RUN" -eq 0 ]] && [[ -d "$PSTACK_DIR" ]] && [[ -z "$(ls -A "$PSTACK_DIR" 2>/dev/null || true)" ]]; then
      rmdir "$PSTACK_DIR"
      log "rm    .pstack"
    elif [[ -d "$PSTACK_DIR" ]]; then
      log "keep  .pstack (contains files this installer does not own)"
    fi
  fi
}

install_or_update() {
  fetch_upstream
  [[ "$DRY_RUN" -eq 1 ]] && { print_model_notice; return 0; }
  : >"$MANIFEST"
  install_skills
  write_models
  write_instructions
  ensure_gitignore
  write_state
  print_model_notice
}

guard_cwd
guard_skill_layout

case "$ACTION" in
  install|update) install_or_update ;;
  uninstall) uninstall ;;
esac
