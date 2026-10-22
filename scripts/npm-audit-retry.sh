#!/usr/bin/env bash
# Run `npm audit` and retry only when the registry or network fails.
# A real audit report with findings at or above the level fails immediately.
#
# usage: scripts/npm-audit-retry.sh [npm audit args...]
# env:   AUDIT_ATTEMPTS (default 3), AUDIT_TIMEOUT seconds per attempt (default 60),
#        AUDIT_BACKOFF initial seconds before a retry, doubles each time (default 10)
set -uo pipefail

attempts="${AUDIT_ATTEMPTS:-3}"
attempt_timeout="${AUDIT_TIMEOUT:-60}"
backoff="${AUDIT_BACKOFF:-10}"

out="$(mktemp)"
err="$(mktemp)"
trap 'rm -f "$out" "$err"' EXIT

# Prints "report" when stdout is a genuine audit report (npm only emits
# auditReportVersion/metadata when the registry answered), "error" otherwise.
classify() {
  # shellcheck disable=SC2016
  node -e '
    let d;
    try { d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); }
    catch { console.log("error"); process.exit(0); }
    console.log(d && !d.error && d.metadata && d.metadata.vulnerabilities ? "report" : "error");
  ' "$1"
}

summarize() {
  # shellcheck disable=SC2016
  node -e '
    const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    for (const [n, v] of Object.entries(d.vulnerabilities || {}))
      console.log(`${v.severity.padEnd(9)} ${n}${v.fixAvailable ? "" : " (no fix available)"}`);
    console.log(JSON.stringify(d.metadata.vulnerabilities));
  ' "$1"
}

for ((i = 1; i <= attempts; i++)); do
  echo "npm audit attempt $i/$attempts (timeout ${attempt_timeout}s)"
  timeout --kill-after=5 "$attempt_timeout" npm audit --json "$@" >"$out" 2>"$err"
  status=$?

  if [[ $status -eq 0 ]]; then
    echo "npm audit clean"
    exit 0
  fi

  if [[ $status -ne 124 && $status -ne 137 && "$(classify "$out")" == "report" ]]; then
    echo "::error::npm audit found vulnerabilities"
    summarize "$out"
    exit 1
  fi

  # No valid report. Retry only registry/network failures and timeouts.
  msg="$(cat "$err" "$out" 2>/dev/null)"
  if [[ $status -eq 124 || $status -eq 137 ]] ||
    grep -Eqi 'ETIMEDOUT|ECONNRESET|ECONNREFUSED|ENOTFOUND|EAI_AGAIN|ESOCKETTIMEDOUT|EPIPE|network|socket hang up|audit endpoint returned an error|\b50[0-9]\b|Service Unavailable|Bad Gateway|Gateway Time-?out|Too Many Requests|\b429\b' <<<"$msg"; then
    echo "::warning::npm audit attempt $i failed with a registry/network error (exit $status)"
    head -c 2000 <<<"$msg"
    echo
    if ((i < attempts)); then
      echo "retrying in ${backoff}s"
      sleep "$backoff"
      backoff=$((backoff * 2))
      continue
    fi
    echo "::error::npm audit registry unavailable after $attempts attempts; not a vulnerability finding"
    exit 1
  fi

  echo "::error::npm audit failed with a non-retryable error (exit $status)"
  head -c 2000 <<<"$msg"
  echo
  exit 1
done
