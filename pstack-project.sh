#!/usr/bin/env bash
# pstack-project.sh — install, update, or uninstall pstack in the current directory
# for Claude Code and Grok Build via .agents / .claude (project scope).
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
HASH_MARKER_BEGIN="# pstack:managed:begin"
HASH_MARKER_END="# pstack:managed:end"
OWNED_STAMP=".pstack-owned"

PSTACK_DIR="${ROOT}/.pstack"
SRC_DIR="${PSTACK_DIR}/src"
MANIFEST="${PSTACK_DIR}/manifest"
STATE="${PSTACK_DIR}/state"

AGENTS_SKILLS="${ROOT}/.agents/skills"
CLAUDE_SKILLS="${ROOT}/.claude/skills"
MODELS_MD="${ROOT}/.agents/pstack-models.md"
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
  for p in "$AGENTS_SKILLS" "$CLAUDE_SKILLS"; do
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
  record ".agents/skills"
  record ".claude/skills"

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

models_md_body_claude() {
  cat <<'EOF'
# pstack-managed: true
# pstack-managed-id: ecociel-pstack-project
# pstack model configuration. Claude slugs only.
# Grok Build reads .agents/ and .claude/ in this repo; there is no
# separate .grok model sheet from this installer.
#
# How to think about this file
# ----------------------------
# 1. Pick the parent Claude Code model first (`/model`). That is the
#    top-level choice. It sets cost, latency, and the default brain for
#    anything not pinned below.
# 2. inherit-parent / auto means the child omits its model field and
#    follows that parent. Use this on remotes and whenever you only have
#    one usable model. A missing line falls back to the skill default.
# 3. Pin a role only when it should differ from the parent: Sonnet for
#    mechanical work, Opus for judgment. Stay inside the Claude family.
# 4. Write only slugs Claude Code will spawn (`/model` list, Agent tool).
#    Cursor slugs (claude-opus-5-5-max) belong in Cursor, not here.
# 5. A comma-separated value is a panel: one child per entry. List
#    length is fan-out. Both entries must still be Claude models.
#
# Role families (Lauren's split, still the right shape)
# -----------------------------------------------------
# Mechanical / throughput  feature, refactoring, bug-fix, perf, hillclimb,
#                          how explorer, why investigators, swarm workers
# Judgment / prose         judgment and prose, hardest tasks, how explainer,
#                          why synthesizer, reflect judgment
# Panels                   how critics, arena, architect, interrogate
#
# budget: high
#
# Active map: inherit-parent so remotes follow the parent session.

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

# --- late September 2026 Claude-only pin (commented) ---
# Opus 5.5 landed 2026-09-22 (id claude-opus-5-5, alias `opus` on
# Claude Code 2.1.280+). Sonnet 5 is the mechanical default
# (id claude-sonnet-5, alias `sonnet`). Uncomment this block and
# comment out the inherit-parent lines above only after `/model`
# lists these slugs. Do not add grok-4.7 here.
#
# feature, refactoring: claude-sonnet-5
# bug-fix: claude-sonnet-5
# perf-issue: claude-sonnet-5
# hillclimb: claude-sonnet-5
# judgment and prose: claude-opus-5-5
# hardest tasks: claude-opus-5-5
# how explorer: claude-sonnet-5
# how explainer: claude-opus-5-5
# how critics: claude-opus-5-5, claude-sonnet-5
# why investigators: claude-sonnet-5
# why synthesizer: claude-opus-5-5
# reflect tooling: claude-sonnet-5
# reflect judgment, divergent, synthesizer: claude-opus-5-5
# arena runners: claude-opus-5-5, claude-sonnet-5
# arena cross-judge pool: claude-opus-5-5, claude-sonnet-5
# swarm workers: claude-sonnet-5
# architect runners: claude-opus-5-5, claude-sonnet-5
# interrogate reviewers: claude-opus-5-5, claude-sonnet-5
EOF
}


instruction_block() {
  cat <<EOF
${MARKER_BEGIN}
pstack is installed in this repository (project scope).
Skills live in \`.agents/skills/\` and are linked from \`.claude/skills/\`.
Grok Build uses those same directories; this installer does not write \`.grok/\`.
Model config (edit this): \`.agents/pstack-models.md\`
Project files win over home-directory sheets.
Use poteto-mode / /poteto-mode for non-trivial engineering work.
Do not delete generated verification skills (\`verify-*\` other than \`verify-commands\`).
${MARKER_END}
EOF
}

count_exact_lines() {
  local file="$1"
  local line="$2"
  grep -Fxc "$line" "$file" 2>/dev/null || true
}

explain_markers() {
  local file="$1"
  local begin="$2"
  local end="$3"
  local begins="${4:-?}"
  local ends="${5:-?}"
  cat >&2 <<EOF

What this means
  This installer only edits the region between two exact marker lines:

    ${begin}
    ...pstack-managed text...
    ${end}

  "Unbalanced" means ${file} does not contain exactly one start line and
  one matching end line (counted ${begins} start, ${ends} end).
  The file was left unchanged.

  Typical causes:
    - a space or comment after the marker (the whole line must match)
    - the end marker was deleted or edited
    - the marker text was quoted in a sentence instead of sitting alone
    - two start markers and one end marker, or the reverse

How to fix
  1. Open ${file}
  2. Either restore both markers as exact whole lines and delete any
     extra copies, then rerun this script
  3. Or delete both marker lines and everything between them if you do
     not want pstack to manage that file; the next install will append
     a fresh block at the end
EOF
}

replace_marked_section() {
  local file="$1"
  local begin="$2"
  local end="$3"
  local block="$4"
  local tmp err status
  tmp="$(mktemp)"
  err="$(mktemp)"
  # macOS awk rejects newlines in -v strings. Pass the block through ENVIRON.
  if ! PSTACK_BLOCK="$block" awk -v begin="$begin" -v end="$end" '
    $0 == begin {
      if (in_block) { extra_begin = 1 }
      printf "%s", ENVIRON["PSTACK_BLOCK"]
      if (ENVIRON["PSTACK_BLOCK"] != "" && ENVIRON["PSTACK_BLOCK"] !~ /\n$/) {
        printf "\n"
      }
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
      if (extra_end || extra_begin) {
        print "unmatched pstack marker" > "/dev/stderr"
        exit 2
      }
    }
  ' "$file" >"$tmp" 2>"$err"; then
    status=$?
    rm -f "$tmp"
    if grep -q 'newline in string' "$err" 2>/dev/null; then
      rm -f "$err"
      die "failed to rewrite ${file}: this awk cannot take a multi-line pstack block. Update pstack-project.sh (ENVIRON pass)."
    fi
    cat "$err" >&2 || true
    rm -f "$err"
    explain_markers "$file" "$begin" "$end"
    die "refusing to edit ${file}: pstack markers are unbalanced (awk exit ${status})"
  fi
  rm -f "$err"
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
    explain_markers "$file" "$begin" "$end" "$begins" "$ends"
    die "refusing to edit ${file}: begin/end pstack markers are unbalanced (begin=${begins} end=${ends})"
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
    explain_markers "$file" "$begin" "$end" "$begins" "$ends"
    die "refusing to edit ${file}: begin/end pstack markers are unbalanced (begin=${begins} end=${ends})"
  fi
  replace_marked_section "$file" "$begin" "$end" ""
  log "patch $(relpath "$file") (pstack section removed)"
}

write_models() {
  models_md_body_claude | write_owned_file "$MODELS_MD" skip-if-exists
}

write_instructions() {
  upsert_marked_section "$CLAUDE_MD" "$MARKER_BEGIN" "$MARKER_END" "$(instruction_block)"
  upsert_marked_section "$AGENTS_MD" "$MARKER_BEGIN" "$MARKER_END" "$(instruction_block)"
}

ensure_gitignore() {
  local block
  block="$(printf '%s\n%s\n%s\n' "$HASH_MARKER_BEGIN" ".pstack/" "$HASH_MARKER_END")"
  upsert_marked_section "$GITIGNORE" "$HASH_MARKER_BEGIN" "$HASH_MARKER_END" "$block"
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

The sheet uses inherit-parent so remotes follow the parent session model.
A commented late-September 2026 Claude pin is in the file
(claude-sonnet-5 / claude-opus-5-5). Existing model files are not overwritten.
Grok Build reads .agents/ and .claude/; this installer does not write .grok/.
EOF
}

cleanup_legacy_grok() {
  # Older installer versions wrote .grok/. Stop creating it; drop files we owned.
  local grok_skills="${ROOT}/.grok/skills"
  local path full
  if [[ -d "$grok_skills" && ! -L "$grok_skills" ]]; then
    assert_under_root "$grok_skills"
    shopt -s nullglob
    for path in "$grok_skills"/*; do
      remove_owned_skill_entry "$path"
    done
    shopt -u nullglob
  fi
  for full in \
    "${ROOT}/.grok/rules/pstack-models.md" \
    "${ROOT}/.grok/pstack-models.toml" \
    "${ROOT}/.grok/rules/pstack.md"
  do
    if exists_any "$full" && is_managed_file "$full"; then
      run_rm -f "$full"
      log "rm    $(relpath "$full") (legacy .grok file; Grok reads .agents/.claude)"
    fi
  done
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
  strip_marked_section "$GITIGNORE" "$HASH_MARKER_BEGIN" "$HASH_MARKER_END"
  cleanup_legacy_grok

  local base path
  for base in "$AGENTS_SKILLS" "$CLAUDE_SKILLS"; do
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
    for full in "$MODELS_MD"; do
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
  cleanup_legacy_grok
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
