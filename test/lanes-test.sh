#!/usr/bin/env bash
# Exercises bin/lanes against a throwaway repo with a local bare "origin".
# Uses lanes.merge=push, so it needs neither gh nor a network.
# Run: test/lanes-test.sh
set -u
LANES="$(cd "$(dirname "$0")/.." && pwd)/bin/lanes"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
pass=0 fail=0
ok() {
  pass=$((pass + 1))
  echo "PASS: $1"
}
bad() {
  fail=$((fail + 1))
  echo "FAIL: $1"
}
expect() { # expect <name> <command...>: command must succeed
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi
}
refuse() { # refuse <name> <command...>: command must fail
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then bad "$name"; else ok "$name"; fi
}

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init -q --bare -b main "$W/origin.git"
git clone -q "$W/origin.git" "$W/repo" 2>/dev/null
cd "$W/repo" || exit 1
echo base >file && git add file && git commit -qm base && git push -q origin main
git remote set-head origin main
git config lanes.count 2
git config lanes.merge push
# The gate fails whenever the tree contains a file named BROKEN.
git config lanes.gate '! test -e BROKEN'

expect "init creates lanes" "$LANES" init
[ -d "$W/repo-lanes/lane-1" ] && [ -d "$W/repo-lanes/lane-2" ] && ok "lanes beside the repo" || bad "lanes beside the repo"

# work <branch> <file>: lease a lane, commit one file, push, release.
work() {
  local dir
  dir=$("$LANES" acquire "$1" 2>/dev/null) || return 1
  echo "$1" >"$dir/$2"
  git -C "$dir" add "$2" && git -C "$dir" commit -qm "$1" && git -C "$dir" push -q origin "$1" 2>/dev/null
  "$LANES" release "${dir##*-}" 2>/dev/null
}

d1=$("$LANES" acquire feat/a 2>/dev/null)
d2=$("$LANES" acquire feat/b 2>/dev/null)
[ -n "$d1" ] && [ -n "$d2" ] && [ "$d1" != "$d2" ] && ok "two leases, two lanes" || bad "two leases, two lanes"
refuse "third lease refused when full" "$LANES" acquire feat/c
echo wip >"$d1/wip"
refuse "release refuses uncommitted work" "$LANES" release 1
git -C "$d1" add wip && git -C "$d1" commit -qm wip
refuse "release refuses unpushed commits" "$LANES" release 1
expect "release --force discards" "$LANES" release 1 --force
[ ! -e "$d1/wip" ] && ok "forced release reset the tree" || bad "forced release reset the tree"
expect "clean release" "$LANES" release 2

work feat/good good.txt
work feat/broken BROKEN
"$LANES" train feat/good feat/broken >"$W/train.log" 2>&1
grep -q '^TRAIN feat/good: LANDED' "$W/train.log" && ok "green branch lands" || bad "green branch lands"
grep -q '^TRAIN feat/broken: FAILED (gate' "$W/train.log" && ok "red branch is refused" || bad "red branch is refused"
git fetch -q origin
git cat-file -e origin/main:good.txt 2>/dev/null && ok "main has the landed file" || bad "main has the landed file"
git cat-file -e origin/main:BROKEN 2>/dev/null && bad "main stays clean" || ok "main stays clean"
git rev-parse -q --verify refs/remotes/origin/feat/good >/dev/null && bad "landed branch deleted" || ok "landed branch deleted"

# Two branches editing the same line: the second conflicts once the first lands.
work feat/x1 file
work feat/x2 file
"$LANES" train feat/x1 feat/x2 >"$W/train2.log" 2>&1
grep -q '^TRAIN feat/x1: LANDED' "$W/train2.log" && ok "first of a conflicting pair lands" || bad "first of a conflicting pair lands"
grep -q '^TRAIN feat/x2: FAILED (conflicts' "$W/train2.log" && ok "conflict is reported" || bad "conflict is reported"

# A branch behind main is rebased before the gate, so it lands on top.
work feat/behind behind.txt
git pull -q --ff-only origin main
echo moved >moved.txt && git add moved.txt && git commit -qm moved && git push -q origin HEAD:main
"$LANES" train feat/behind >"$W/train3.log" 2>&1
git fetch -q origin
git cat-file -e origin/main:behind.txt 2>/dev/null && git cat-file -e origin/main:moved.txt 2>/dev/null &&
  ok "branch behind main is rebased and lands" || bad "branch behind main is rebased and lands"

# Main moves while the gate runs: the train must re-test, never land the
# untested combination. The gate pushes a commit to main the first time only.
git clone -q "$W/origin.git" "$W/other" 2>/dev/null
(cd "$W/other" && echo race >race.txt && git add race.txt && git commit -qm race)
work feat/race race-branch.txt
git config lanes.gate "! test -e BROKEN && { test -e '$W/raced' || { touch '$W/raced'; git -C '$W/other' push -q origin HEAD:main; }; }"
"$LANES" train feat/race >"$W/train4.log" 2>&1
git config lanes.gate '! test -e BROKEN'
grep -q 'moved during the gate; retrying feat/race' "$W/train4.log" && grep -q '^TRAIN feat/race: LANDED' "$W/train4.log" &&
  ok "main moving mid-gate forces a re-test" || bad "main moving mid-gate forces a re-test"
git fetch -q origin
git cat-file -e origin/main:race.txt 2>/dev/null && git cat-file -e origin/main:race-branch.txt 2>/dev/null &&
  ok "both the racing commit and the branch are on main" || bad "both the racing commit and the branch are on main"

# A re-acquired branch that exists on origin resumes from it.
work feat/resume r1.txt
d=$("$LANES" acquire feat/resume 2>/dev/null)
[ -e "$d/r1.txt" ] && ok "re-acquire resumes from origin" || bad "re-acquire resumes from origin"
"$LANES" release "${d##*-}" >/dev/null 2>&1

refuse "train without a gate refuses" env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=lanes.gate GIT_CONFIG_VALUE_0= "$LANES" train feat/resume
(cd "$d" && "$LANES" status | grep -q "base $W/repo-lanes") && ok "status from inside a lane sees the same pool" || bad "status from inside a lane sees the same pool"

echo "----"
echo "$pass passed, $fail failed"
exit "$fail"
