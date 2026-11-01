#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Checks that pwmstream-report's update check behaves: it stops when a newer release exists unless
# --force, and carries on when offline, not installed or without curl. Uses a mock dpkg-query and a
# file:// release reply, so there is no network access.
set -eu
work="$PWD/.report-check"
mkdir "$work"
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir "$work/bin"
cat > "$work/bin/dpkg-query" <<'EOF'
#!/bin/sh
[ -n "${TEST_INSTALLED:-}" ] || exit 1
printf '%s' "$TEST_INSTALLED"
EOF
chmod +x "$work/bin/dpkg-query"
printf '{"tag_name": "v0.2.0"}' > "$work/latest.json"
printf '{"message": "Not Found"}' > "$work/none.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
run() {
	PATH="$work/bin:$PATH" PWMSTREAM_RELEASE_URL="file://$work/${REPLY_FILE:-latest.json}" \
		BOOT_DIR="$work" sh ./pwmstream-report.sh "$@" > "$work/out" 2> "$work/err"
}

TEST_INSTALLED=0.1.0 run && fail "outdated install was not rejected"
grep -q 'out of date' "$work/err" || fail "no outdated message"
grep -q -- '--force' "$work/err" || fail "message does not mention --force"
[ ! -s "$work/out" ] || fail "report printed despite outdated install"

TEST_INSTALLED=0.1.0 run --force || fail "--force failed"
grep -q 'WARNING.*out of date' "$work/err" || fail "--force gave no warning"
grep -q '^update check: OUTDATED (installed 0.1.0, latest 0.2.0)$' "$work/out" || fail "report lacks outdated line"

TEST_INSTALLED=0.2.0 run || fail "current install rejected"
grep -q '^update check: up to date (0.2.0)$' "$work/out" || fail "up to date line"

TEST_INSTALLED=0.3.0 run || fail "newer-than-release install rejected"

TEST_INSTALLED=0.1.0 REPLY_FILE=none.json run || fail "missing release blocked the report"
grep -q '^update check: unavailable (no release found)$' "$work/out" || fail "no-release line"

TEST_INSTALLED=0.1.0 REPLY_FILE=absent.json run || fail "unreachable GitHub blocked the report"
grep -q '^update check: unavailable (could not reach GitHub)$' "$work/out" || fail "unreachable line"

run || fail "source checkout (no package) blocked"
grep -q '^update check: skipped' "$work/out" || fail "skipped line"

run --bogus && fail "unknown option accepted"
echo "PASS: report update-check cases."
