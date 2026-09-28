#!/usr/bin/env bash
# Regression tests for destructive paths in pstack-project.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${ROOT}/pstack-project.sh"
[[ -f "$SCRIPT" ]] || { echo "missing $SCRIPT"; exit 1; }

FAIL=0
pass() { printf 'ok  %s\n' "$1"; }
fail() { printf 'not ok  %s\n' "$1"; FAIL=1; }

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

make_upstream() {
  local up="$1"
  mkdir -p "$up/skills/why" "$up/skills/how" "$up/skills/verify-commands"
  printf '# why\n' >"$up/skills/why/SKILL.md"
  printf '# how\n' >"$up/skills/how/SKILL.md"
  printf '# verify-commands\n' >"$up/skills/verify-commands/SKILL.md"
  git -C "$up" init -q
  git -C "$up" config user.email t@example.com
  git -C "$up" config user.name t
  git -C "$up" add skills
  git -C "$up" commit -qm init
}

make_project() {
  local proj="$1"
  mkdir -p "$proj"
  git -C "$proj" init -q
  git -C "$proj" config user.email t@example.com
  git -C "$proj" config user.name t
  printf '# project\n' >"$proj/README.md"
  git -C "$proj" add README.md
  git -C "$proj" commit -qm init
}

run_install() {
  local proj="$1"
  local up="$2"
  (
    cd "$proj"
    PSTACK_REPO="$up" PSTACK_REF="master" \
      bash "$SCRIPT" install
  )
}

# Some git inits use main, some master.
branch_of() { git -C "$1" rev-parse --abbrev-ref HEAD; }

UP="$WORKDIR/upstream"
make_upstream "$UP"
UP_REF="$(branch_of "$UP")"

# --- 1. foreign symlink in skill dir survives uninstall
PROJ="$WORKDIR/p1"
make_project "$PROJ"
mkdir -p "$PROJ/.claude/skills" "$PROJ/shared/my-skill"
printf 'mine\n' >"$PROJ/shared/my-skill/SKILL.md"
ln -s "../../shared/my-skill" "$PROJ/.claude/skills/my-skill"
(
  cd "$PROJ"
  PSTACK_REPO="$UP" PSTACK_REF="$UP_REF" bash "$SCRIPT" install >/dev/null
  PSTACK_REPO="$UP" PSTACK_REF="$UP_REF" bash "$SCRIPT" uninstall >/dev/null
)
if [[ -L "$PROJ/.claude/skills/my-skill" ]]; then
  pass "uninstall keeps foreign skill symlink"
else
  fail "uninstall deleted foreign skill symlink"
fi

# --- 2. install does not steal a foreign why symlink
PROJ="$WORKDIR/p2"
make_project "$PROJ"
mkdir -p "$PROJ/.claude/skills" "$PROJ/mine/why"
printf 'mine-why\n' >"$PROJ/mine/why/SKILL.md"
ln -s "../../mine/why" "$PROJ/.claude/skills/why"
(
  cd "$PROJ"
  PSTACK_REPO="$UP" PSTACK_REF="$UP_REF" bash "$SCRIPT" install >/dev/null
)
target="$(readlink "$PROJ/.claude/skills/why")"
if [[ "$target" == "../../mine/why" ]]; then
  pass "install leaves foreign why symlink"
else
  fail "install replaced foreign why symlink with $target"
fi

# --- 3. trailing space on end marker refuses to wipe CLAUDE.md
PROJ="$WORKDIR/p3"
make_project "$PROJ"
cat >"$PROJ/CLAUDE.md" <<'EOF'
# Top
<!-- pstack:managed:begin -->
old
<!-- pstack:managed:end --> 
# Bottom
EOF
if (
  cd "$PROJ"
  PSTACK_REPO="$UP" PSTACK_REF="$UP_REF" bash "$SCRIPT" install >/dev/null
); then
  fail "install accepted unbalanced CLAUDE.md markers"
else
  if grep -q '# Bottom' "$PROJ/CLAUDE.md" && grep -q '# Top' "$PROJ/CLAUDE.md"; then
    pass "unbalanced markers leave CLAUDE.md intact"
  else
    fail "unbalanced markers still damaged CLAUDE.md"
  fi
fi

# --- 4. customized copy with leftover stamp is not deleted
PROJ="$WORKDIR/p4"
make_project "$PROJ"
(
  cd "$PROJ"
  PSTACK_REPO="$UP" PSTACK_REF="$UP_REF" bash "$SCRIPT" install >/dev/null
)
cp -R "$PROJ/.agents/skills/why" "$PROJ/.agents/skills/my-why"
(
  cd "$PROJ"
  PSTACK_REPO="$UP" PSTACK_REF="$UP_REF" bash "$SCRIPT" uninstall >/dev/null
)
if [[ -d "$PROJ/.agents/skills/my-why" ]]; then
  pass "uninstall keeps renamed copy even if stamp was copied"
else
  fail "uninstall deleted renamed stamped copy my-why"
fi

# --- 5. unrelated .pstack/data survives uninstall
PROJ="$WORKDIR/p5"
make_project "$PROJ"
mkdir -p "$PROJ/.pstack"
printf 'keep\n' >"$PROJ/.pstack/data"
(
  cd "$PROJ"
  bash "$SCRIPT" uninstall >/dev/null
)
if [[ -f "$PROJ/.pstack/data" ]]; then
  pass "uninstall keeps foreign .pstack/data"
else
  fail "uninstall deleted unrelated .pstack/data"
fi

# --- 6. refuse $HOME without --force
if (
  cd "$HOME"
  bash "$SCRIPT" uninstall >/dev/null
); then
  fail "uninstall in \$HOME should fail without --force"
else
  pass "refuses to run in \$HOME"
fi

# --- 7. skill folder symlink escaping the project is refused
PROJ="$WORKDIR/p7"
make_project "$PROJ"
OUT="$WORKDIR/outside-skills"
mkdir -p "$OUT"
mkdir -p "$PROJ/.agents"
ln -s "$OUT" "$PROJ/.agents/skills"
if (
  cd "$PROJ"
  PSTACK_REPO="$UP" PSTACK_REF="$UP_REF" bash "$SCRIPT" install >/dev/null
); then
  fail "install allowed skill dir outside the project"
else
  pass "refuses skill dir that resolves outside the project"
fi

# --- 8. CLAUDE.md symlink stays a symlink; mode is not 0600
PROJ="$WORKDIR/p8"
make_project "$PROJ"
printf '# agents\n' >"$PROJ/AGENTS.md"
ln -s AGENTS.md "$PROJ/CLAUDE.md"
chmod 664 "$PROJ/AGENTS.md"
(
  cd "$PROJ"
  PSTACK_REPO="$UP" PSTACK_REF="$UP_REF" bash "$SCRIPT" install >/dev/null
)
if [[ -L "$PROJ/CLAUDE.md" ]]; then
  pass "CLAUDE.md remains a symlink"
else
  fail "CLAUDE.md symlink was replaced by a regular file"
fi
mode="$(stat -c '%a' "$PROJ/AGENTS.md" 2>/dev/null || stat -f '%OLp' "$PROJ/AGENTS.md")"
if [[ "$mode" != "600" && "$mode" != "0600" ]]; then
  pass "instruction file mode preserved ($mode)"
else
  fail "instruction file mode tightened to $mode"
fi

# --- 9. notes inside a vendored skill survive update
PROJ="$WORKDIR/p9"
make_project "$PROJ"
(
  cd "$PROJ"
  PSTACK_REPO="$UP" PSTACK_REF="$UP_REF" bash "$SCRIPT" install >/dev/null
)
printf 'notes\n' >"$PROJ/.agents/skills/why/MY-NOTES.md"
(
  cd "$PROJ"
  PSTACK_REPO="$UP" PSTACK_REF="$UP_REF" bash "$SCRIPT" update >/dev/null
)
if [[ -f "$PROJ/.agents/skills/why/MY-NOTES.md" ]]; then
  pass "update keeps MY-NOTES.md inside a vendored skill"
else
  fail "update deleted MY-NOTES.md inside why/"
fi

# --- 10. .claude/skills -> .agents/skills does not create recursive links
PROJ="$WORKDIR/p10"
make_project "$PROJ"
mkdir -p "$PROJ/.agents/skills" "$PROJ/.claude"
ln -s "../.agents/skills" "$PROJ/.claude/skills"
(
  cd "$PROJ"
  PSTACK_REPO="$UP" PSTACK_REF="$UP_REF" bash "$SCRIPT" install >/dev/null
)
if [[ -f "$PROJ/.agents/skills/why/SKILL.md" ]] && [[ ! -L "$PROJ/.agents/skills/why" ]]; then
  pass "shared skills folder does not become a self-link"
else
  fail "shared skills folder was turned into a recursive symlink"
fi

# --- 11. installed links are relative
PROJ="$WORKDIR/p11"
make_project "$PROJ"
(
  cd "$PROJ"
  PSTACK_REPO="$UP" PSTACK_REF="$UP_REF" bash "$SCRIPT" install >/dev/null
)
link="$(readlink "$PROJ/.claude/skills/why")"
case "$link" in
  /*) fail "claude why link is absolute: $link" ;;
  *) pass "claude why link is relative ($link)" ;;
esac

# --- 12. bad PSTACK_REF fails
PROJ="$WORKDIR/p12"
make_project "$PROJ"
if (
  cd "$PROJ"
  PSTACK_REPO="$UP" PSTACK_REF="no-such-ref" bash "$SCRIPT" install >/dev/null
); then
  fail "bad PSTACK_REF should fail"
else
  pass "bad PSTACK_REF is an error"
fi

# --- 14. updating an existing balanced CLAUDE.md block succeeds
PROJ="$WORKDIR/p14"
make_project "$PROJ"
cat >"$PROJ/CLAUDE.md" <<'EOF'
# Top
<!-- pstack:managed:begin -->
old managed text
<!-- pstack:managed:end -->
# Bottom
EOF
if (
  cd "$PROJ"
  PSTACK_REPO="$UP" PSTACK_REF="$UP_REF" bash "$SCRIPT" install >/dev/null
) && grep -q '# Top' "$PROJ/CLAUDE.md" && grep -q '# Bottom' "$PROJ/CLAUDE.md" && grep -q 'pstack is installed' "$PROJ/CLAUDE.md"; then
  pass "updates a balanced CLAUDE.md block without dropping user text"
else
  fail "failed to update a balanced CLAUDE.md block"
fi

# --- 15. unbalanced marker error explains how to fix
PROJ="$WORKDIR/p15"
make_project "$PROJ"
cat >"$PROJ/CLAUDE.md" <<'EOF'
# Top
<!-- pstack:managed:begin -->
old
<!-- pstack:managed:end --> 
# Bottom
EOF
out="$(
  cd "$PROJ"
  PSTACK_REPO="$UP" PSTACK_REF="$UP_REF" bash "$SCRIPT" install 2>&1 || true
)"
if printf '%s' "$out" | grep -q 'How to fix' && printf '%s' "$out" | grep -q 'What this means'; then
  pass "unbalanced marker error explains meaning and fix"
else
  fail "unbalanced marker error lacked explanation"
fi
PROJ="$WORKDIR/p13"
make_project "$PROJ"
(
  cd "$PROJ"
  PSTACK_REPO="$UP" PSTACK_REF="$UP_REF" bash "$SCRIPT" install --dry-run >/dev/null
)
if [[ -d "$PROJ/.agents/skills/why" ]]; then
  fail "dry-run created skill files"
else
  pass "dry-run creates no skill files"
fi

if [[ "$FAIL" -eq 0 ]]; then
  printf '\nall tests passed\n'
  exit 0
fi
printf '\nsome tests failed\n'
exit 1
