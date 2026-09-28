#!/usr/bin/env bash
# pstack-project.sh — install, update, or uninstall pstack in the current directory
# for Claude Code and Grok Build (project scope, remote-safe).
#
# Usage:
#   ./pstack-project.sh install
#   ./pstack-project.sh update
#   ./pstack-project.sh uninstall
#   ./pstack-project.sh uninstall --purge-config
#
# Env:
#   PSTACK_REPO   git URL (default: https://github.com/mdsmithaustin/pstack.git)
#   PSTACK_REF    branch/tag/commit (default: main)
#   PSTACK_SKILLS subdirectory inside the repo that holds skills (default: skills)
#
# pstack playbooks © Lauren Tan (@poteto). This installer only vendors and wires them.

set -euo pipefail

ROOT="$(pwd)"
ACTION="${1:-}"
PURGE_CONFIG=0
if [[ "${2:-}" == "--purge-config" ]]; then
  PURGE_CONFIG=1
fi

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

# Core pstack skill names. Generated project verifiers (verify-*) are never listed.
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

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: pstack-project.sh <install|update|uninstall> [--purge-config]

install     Vendor pstack skills into this repo and write model config if missing
update      Refresh owned pstack skills from upstream; keep model config and verify-*
uninstall   Remove owned pstack files only; keep verify-* and (unless --purge-config) model config
EOF
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
  printf '%s' "$PSTACK_SKILLS_ALLOW" | grep -qx "$name"
}

is_owned_path() {
  local path="$1"
  [[ -f "$path/$OWNED_STAMP" ]] && return 0
  if [[ -f "$MANIFEST" ]] && grep -Fqx "$path" "$MANIFEST" 2>/dev/null; then
    return 0
  fi
  return 1
}

is_managed_file() {
  local path="$1"
  [[ -f "$path" ]] || return 1
  grep -q "pstack-managed-id: ${MANAGED_ID}" "$path" 2>/dev/null
}

ensure_dir() {
  mkdir -p "$1"
}

record() {
  local rel="$1"
  ensure_dir "$(dirname "$MANIFEST")"
  touch "$MANIFEST"
  grep -Fqx "$rel" "$MANIFEST" 2>/dev/null || printf '%s\n' "$rel" >>"$MANIFEST"
}

write_owned_file() {
  local dest="$1"
  local mode="${2:-skip-if-foreign}"
  local tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  if [[ -e "$dest" ]]; then
    if is_managed_file "$dest" || [[ "$mode" == "force-owned" ]]; then
      :
    elif [[ "$mode" == "skip-if-exists" ]]; then
      rm -f "$tmp"
      printf 'keep  %s (already exists; not overwritten)\n' "${dest#"$ROOT"/}"
      return 0
    else
      rm -f "$tmp"
      printf 'skip  %s (exists and is not a pstack-managed file)\n' "${dest#"$ROOT"/}"
      return 0
    fi
  fi
  ensure_dir "$(dirname "$dest")"
  mv "$tmp" "$dest"
  record "${dest#"$ROOT"/}"
  printf 'write %s\n' "${dest#"$ROOT"/}"
}

stamp_dir() {
  local dest="$1"
  printf 'pstack-managed-id: %s\n' "$MANAGED_ID" >"${dest}/${OWNED_STAMP}"
  record "${dest#"$ROOT"/}/${OWNED_STAMP}"
}

install_skill_dir() {
  local src="$1"
  local dest="$2"
  local name
  name="$(basename "$dest")"

  if is_verify_skill "$name"; then
    printf 'keep  %s (generated verification skill)\n' "${dest#"$ROOT"/}"
    return 0
  fi

  if [[ -e "$dest" || -L "$dest" ]]; then
    if [[ -L "$dest" ]]; then
      local target
      target="$(readlink "$dest" || true)"
      case "$target" in
        */.pstack/*|*/.agents/skills/"$name")
          rm -f "$dest"
          ;;
        *)
          printf 'skip  %s (symlink not owned by this installer)\n' "${dest#"$ROOT"/}"
          return 0
          ;;
      esac
    elif is_owned_path "$dest"; then
      rm -rf "$dest"
    else
      printf 'skip  %s (exists and is not a pstack-owned skill)\n' "${dest#"$ROOT"/}"
      return 0
    fi
  fi

  ensure_dir "$(dirname "$dest")"
  mkdir -p "$dest"
  # Copy contents, not a wrapping extra directory.
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete --exclude "$OWNED_STAMP" "$src"/ "$dest"/
  else
    find "$dest" -mindepth 1 -maxdepth 1 ! -name "$OWNED_STAMP" -exec rm -rf {} +
    cp -R "$src"/. "$dest"/
  fi
  stamp_dir "$dest"
  record "${dest#"$ROOT"/}"
  printf 'skill %s\n' "${dest#"$ROOT"/}"
}

link_or_copy_skill() {
  local src="$1"
  local dest="$2"
  local name
  name="$(basename "$dest")"
  if is_verify_skill "$name"; then
    return 0
  fi
  if [[ -e "$dest" || -L "$dest" ]]; then
    if [[ -L "$dest" ]]; then
      rm -f "$dest"
    elif is_owned_path "$dest"; then
      rm -rf "$dest"
    else
      printf 'skip  %s (exists and is not a pstack-owned skill)\n' "${dest#"$ROOT"/}"
      return 0
    fi
  fi
  ensure_dir "$(dirname "$dest")"
  if ln -s "$src" "$dest" 2>/dev/null; then
    record "${dest#"$ROOT"/}"
    printf 'link  %s -> %s\n' "${dest#"$ROOT"/}" "${src#"$ROOT"/}"
  else
    install_skill_dir "$src" "$dest"
  fi
}

fetch_upstream() {
  ensure_dir "$PSTACK_DIR"
  if [[ -d "${SRC_DIR}/.git" ]]; then
    git -C "$SRC_DIR" fetch --depth 1 origin "$PSTACK_REF"
    git -C "$SRC_DIR" checkout --force "FETCH_HEAD"
  else
    rm -rf "$SRC_DIR"
    git clone --depth 1 --branch "$PSTACK_REF" "$PSTACK_REPO" "$SRC_DIR" \
      || git clone --depth 1 "$PSTACK_REPO" "$SRC_DIR"
    if [[ -n "$PSTACK_REF" ]]; then
      git -C "$SRC_DIR" fetch --depth 1 origin "$PSTACK_REF" 2>/dev/null || true
      git -C "$SRC_DIR" checkout --force "$PSTACK_REF" 2>/dev/null \
        || git -C "$SRC_DIR" checkout --force "FETCH_HEAD" 2>/dev/null \
        || true
    fi
  fi
  local rev
  rev="$(git -C "$SRC_DIR" rev-parse HEAD)"
  printf '%s\n' "$rev" >"${PSTACK_DIR}/revision"
  printf 'source %s@%s (%s)\n' "$PSTACK_REPO" "$PSTACK_REF" "$rev"
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

  shopt -s nullglob
  for src in "$src_root"/*/; do
    skill="$(basename "$src")"
    if is_verify_skill "$skill"; then
      continue
    fi
    if ! is_allowlisted_skill "$skill"; then
      printf 'skip  upstream skill %s (not a known pstack skill)\n' "$skill"
      continue
    fi
    dest="${AGENTS_SKILLS}/${skill}"
    install_skill_dir "$src" "$dest"
    link_or_copy_skill "$dest" "${CLAUDE_SKILLS}/${skill}"
    link_or_copy_skill "$dest" "${GROK_SKILLS}/${skill}"
  done
  shopt -u nullglob
}

models_md_body() {
  cat <<'EOF'
# pstack-managed: true
# pstack-managed-id: ecociel-pstack-project
# pstack model configuration (project). One line per role.
# inherit-parent / auto: the child uses the parent session model.
# Delete a line to fall back to the skill default.
#
# Defaults below prefer inherit-parent so Claude Code and Grok Build
# remotes keep working when only one model is available. Adjust slugs
# to models your session can actually spawn.
#
# Suggested split when you have two Grok models:
#   mechanical / explore  -> grok-4.5 (or your fast slug)
#   judgment / prose      -> grok-4.6 (or your default / stronger slug)
# Suggested split on Claude Code:
#   mechanical            -> sonnet
#   judgment / hardest    -> opus
#
# budget: high

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
EOF
}

models_toml_body() {
  cat <<'EOF'
# pstack-managed: true
# pstack-managed-id: ecociel-pstack-project
# tommy-ca / Grok Build overlay. inherit-parent omits spawn_subagent.model.

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
pstack-managed-id: ${MANAGED_ID}

Read \`.grok/rules/pstack-models.md\` and \`.agents/pstack-models.md\` before
any spawn_subagent. Project files win over ~/.grok/rules/pstack-models.md
and ~/.grok/pstack-models.toml.
If a role is inherit-parent or auto, omit the model field.
${GROK_MARKER_END}
EOF
}

upsert_marked_section() {
  local file="$1"
  local begin="$2"
  local end="$3"
  local block="$4"
  ensure_dir "$(dirname "$file")"
  if [[ ! -f "$file" ]]; then
    printf '%s\n' "$block" >"$file"
    record "${file#"$ROOT"/}"
    printf 'write %s (created with pstack section)\n' "${file#"$ROOT"/}"
    return 0
  fi
  if grep -q "$begin" "$file" && grep -q "$end" "$file"; then
    local tmp
    tmp="$(mktemp)"
    awk -v begin="$begin" -v end="$end" -v block="$block" '
      $0 == begin { print block; skip=1; next }
      $0 == end { skip=0; next }
      skip != 1 { print }
    ' "$file" >"$tmp"
    mv "$tmp" "$file"
    printf 'patch %s (pstack section updated)\n' "${file#"$ROOT"/}"
    return 0
  fi
  printf '\n%s\n' "$block" >>"$file"
  printf 'patch %s (pstack section appended)\n' "${file#"$ROOT"/}"
}

strip_marked_section() {
  local file="$1"
  local begin="$2"
  local end="$3"
  [[ -f "$file" ]] || return 0
  if grep -q "$begin" "$file" && grep -q "$end" "$file"; then
    local tmp
    tmp="$(mktemp)"
    awk -v begin="$begin" -v end="$end" '
      $0 == begin { skip=1; next }
      $0 == end { skip=0; next }
      skip != 1 { print }
    ' "$file" >"$tmp"
    mv "$tmp" "$file"
    printf 'patch %s (pstack section removed)\n' "${file#"$ROOT"/}"
  fi
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

write_state() {
  ensure_dir "$PSTACK_DIR"
  cat >"$STATE" <<EOF
repo=${PSTACK_REPO}
ref=${PSTACK_REF}
revision=$(cat "${PSTACK_DIR}/revision" 2>/dev/null || echo unknown)
installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}

print_model_notice() {
  cat <<EOF

Model config (you will probably want to adjust this):
  ${MODELS_MD}

Grok-specific copies (kept in sync only on first write; later edits stay):
  ${MODELS_GROK_MD}
  ${MODELS_GROK_TOML}

The generated sheet uses inherit-parent so Claude Code and Grok Build remotes
work with whatever model the parent session already has. Replace those values
with slugs from \`grok models\` or Claude Code's Agent model list when you
want a real split (fast vs judgment, or a review panel).
EOF
}

install_or_update() {
  command -v git >/dev/null 2>&1 || die "git is required"
  fetch_upstream
  : >"$MANIFEST"
  record ".pstack"
  record ".pstack/src"
  record ".pstack/manifest"
  record ".pstack/state"
  record ".pstack/revision"
  install_skills
  write_models
  write_instructions
  write_state
  print_model_notice
}

uninstall() {
  local path name full
  strip_marked_section "$CLAUDE_MD" "$MARKER_BEGIN" "$MARKER_END"
  strip_marked_section "$AGENTS_MD" "$MARKER_BEGIN" "$MARKER_END"

  # Remove owned skill directories, but never verify-* (except verify-commands).
  for base in "$AGENTS_SKILLS" "$CLAUDE_SKILLS" "$GROK_SKILLS"; do
    [[ -d "$base" ]] || continue
    shopt -s nullglob
    for path in "$base"/*; do
      name="$(basename "$path")"
      if is_verify_skill "$name"; then
        printf 'keep  %s (generated verification skill)\n' "${path#"$ROOT"/}"
        continue
      fi
      if [[ -L "$path" ]]; then
        rm -f "$path"
        printf 'rm    %s\n' "${path#"$ROOT"/}"
        continue
      fi
      if is_owned_path "$path" || is_allowlisted_skill "$name"; then
        if is_owned_path "$path"; then
          rm -rf "$path"
          printf 'rm    %s\n' "${path#"$ROOT"/}"
        else
          printf 'skip  %s (matches a pstack name but has no ownership stamp)\n' "${path#"$ROOT"/}"
        fi
      fi
    done
    shopt -u nullglob
  done

  if [[ "$PURGE_CONFIG" -eq 1 ]]; then
    for full in "$MODELS_MD" "$MODELS_GROK_MD" "$MODELS_GROK_TOML" "$GROK_RULE"; do
      if [[ -f "$full" ]] && is_managed_file "$full"; then
        rm -f "$full"
        printf 'rm    %s\n' "${full#"$ROOT"/}"
      elif [[ -f "$full" ]]; then
        printf 'skip  %s (not pstack-managed; not deleted)\n' "${full#"$ROOT"/}"
      fi
    done
  else
    printf 'keep  model config (pass --purge-config to delete managed sheets)\n'
  fi

  if [[ -d "$PSTACK_DIR" ]]; then
    rm -rf "$PSTACK_DIR"
    printf 'rm    .pstack\n'
  fi
}

case "$ACTION" in
  install|update)
    install_or_update
    ;;
  uninstall)
    uninstall
    ;;
  -h|--help|help|"")
    usage
    [[ -n "$ACTION" ]] || exit 1
    ;;
  *)
    usage
    die "unknown action: $ACTION"
    ;;
esac
