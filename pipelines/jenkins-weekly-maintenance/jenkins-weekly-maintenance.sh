#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ENV_FILE=/etc/jenkins-weekly-maintenance.env
LOG=/var/log/jenkins-weekly-maintenance.log
BACKUP_ROOT=/var/backups/jenkins-weekly-maintenance
JENKINS_HOME="${JENKINS_HOME:-/var/lib/jenkins}"
JENKINS_URL="${JENKINS_URL:-http://192.168.0.104:8080}"
HEALTH_URL="${JENKINS_HEALTH_URL:-http://192.168.0.104:8080/login}"
HEALTH_TIMEOUT=300
mkdir -p "$BACKUP_ROOT"
touch "$LOG"
exec > >(tee -a "$LOG") 2>&1

notify() {
  local subject="$1" body="$2"
  if [[ -z "${SMTP_USER:-}" || -z "${SMTP_PASSWORD:-}" || -z "${SMTP_TO:-}" ]]; then
    echo "SMTP is not configured; cannot send Gmail report."
    return 0
  fi
  python3 - "$subject" "$body" <<'PY'
import os, smtplib, sys
from email.message import EmailMessage
m = EmailMessage()
m["Subject"] = sys.argv[1]
m["From"] = os.environ.get("SMTP_FROM", os.environ["SMTP_USER"])
m["To"] = os.environ["SMTP_TO"]
m.set_content(sys.argv[2])
with smtplib.SMTP(os.environ.get("SMTP_HOST", "smtp.gmail.com"),
                  int(os.environ.get("SMTP_PORT", "587")), timeout=30) as s:
    s.starttls()
    s.login(os.environ["SMTP_USER"], os.environ["SMTP_PASSWORD"])
    s.send_message(m)
PY
}

fail() { echo "ERROR: $*" >&2; exit 1; }

[[ -r "$ENV_FILE" ]] || fail "Missing $ENV_FILE"
# shellcheck disable=SC1090
set -a
source "$ENV_FILE"
set +a
[[ $EUID -eq 0 ]] || fail "Run as root."
[[ -f "$JENKINS_HOME/config.xml" ]] || fail "JENKINS_HOME not found: $JENKINS_HOME/config.xml"

APT_SOURCES="$(grep -Rhs 'pkg.jenkins.io/debian' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || true)"
grep -q 'pkg.jenkins.io/debian' <<<"$APT_SOURCES" || fail "Jenkins Weekly apt repository not found."
if grep -q 'pkg.jenkins.io/debian-stable' <<<"$APT_SOURCES"; then
  fail "LTS repository detected. Refusing to run because Weekly channel was selected."
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BACKUP_ROOT/jenkins-home-$STAMP.tar.gz"
OLD_VERSION="$(dpkg-query -W -f='${Version}' jenkins)"
echo "[$(date -Is)] Starting Jenkins weekly maintenance; current version=$OLD_VERSION"
AVAILABLE_KB="$(df -Pk "$BACKUP_ROOT" | awk 'NR==2 {print $4}')"
(( AVAILABLE_KB > 1048576 )) || fail "Less than 1 GiB free for backup."

SUCCESS=0
SUMMARY="Started: $(date -Is)\nPrevious Jenkins package: $OLD_VERSION\n"
cleanup_report() {
  local code=$?
  if (( SUCCESS == 1 )); then
    notify "[Jenkins Maintenance] SUCCESS" "$SUMMARY\nResult: SUCCESS\nLog: $LOG" || echo "Email notification failed."
  else
    notify "[Jenkins Maintenance] FAILURE" "$SUMMARY\nResult: FAILURE (exit $code)\nReview log: $LOG\nRecovery may require manual intervention." || echo "Email notification failed."
  fi
}
trap cleanup_report EXIT

echo "Creating full JENKINS_HOME backup: $BACKUP"
tar -czpf "$BACKUP" -C "$(dirname "$JENKINS_HOME")" "$(basename "$JENKINS_HOME")"
SUMMARY+="Backup: $BACKUP\n"

# Use Jenkins Script Console to deploy compatible plugin updates from its Update Center.
command -v curl >/dev/null || fail "curl is required."
command -v python3 >/dev/null || fail "python3 is required."
: "${JENKINS_USER:?Set JENKINS_USER in $ENV_FILE}"
: "${JENKINS_API_TOKEN:?Set JENKINS_API_TOKEN in $ENV_FILE}"

CRUMB_JSON="$(curl -fsS -u "$JENKINS_USER:$JENKINS_API_TOKEN" "$JENKINS_URL/crumbIssuer/api/json" || true)"
CRUMB_HEADER=""
if [[ -n "$CRUMB_JSON" ]]; then
  CRUMB_HEADER="$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["crumbRequestField"]+":"+d["crumb"])' <<<"$CRUMB_JSON")"
fi
GROOVY="$(cat <<'GROOVY'
import jenkins.model.Jenkins
import java.util.concurrent.TimeUnit
def j = Jenkins.get()
j.updateCenter.updateAllSites()
def updates = j.updateCenter.getPluginUpdates()
println("PLUGIN_UPDATES_FOUND=" + updates.size())
updates.each { p ->
  println("UPDATING_PLUGIN=" + p.name + ":" + p.version)
  def f = p.deploy(true)
  if (f != null) { f.get(15, TimeUnit.MINUTES) }
}
println("PLUGIN_UPDATE_SUBMISSION_COMPLETE")
GROOVY
)"
CURL_ARGS=(-fsS -u "$JENKINS_USER:$JENKINS_API_TOKEN" -H 'Content-Type: application/x-www-form-urlencoded')
if [[ -n "$CRUMB_HEADER" ]]; then CURL_ARGS+=(-H "$CRUMB_HEADER"); fi
GROOVY_RESULT="$(curl "${CURL_ARGS[@]}" --data-urlencode "script=$GROOVY" "$JENKINS_URL/scriptText")"
echo "$GROOVY_RESULT"
grep -q 'PLUGIN_UPDATE_SUBMISSION_COMPLETE' <<<"$GROOVY_RESULT" || fail "Plugin update script did not complete."
SUMMARY+="Plugin update request completed. See maintenance log for plugin details.\n"

apt-get update
CANDIDATE="$(apt-cache policy jenkins | awk '/Candidate:/ {print $2; exit}')"
[[ -n "$CANDIDATE" && "$CANDIDATE" != "(none)" ]] || fail "No Jenkins package candidate."
echo "Jenkins package candidate: $CANDIDATE"
apt-get install --only-upgrade -y jenkins
systemctl daemon-reload || true
systemctl restart jenkins

DEADLINE=$((SECONDS + HEALTH_TIMEOUT))
HEALTH_OK=0
while (( SECONDS < DEADLINE )); do
  if systemctl is-active --quiet jenkins && curl -fsS --max-time 8 "$HEALTH_URL" >/dev/null; then
    HEALTH_OK=1
    break
  fi
  echo "Waiting for Jenkins health check..."
  sleep 10
done

if (( HEALTH_OK != 1 )); then
  echo "Health check failed. Attempting best-effort recovery."
  systemctl stop jenkins || true
  RESTORE_STAGING="$BACKUP_ROOT/restore-$STAMP"
  mkdir -p "$RESTORE_STAGING"
  tar -xzpf "$BACKUP" -C "$RESTORE_STAGING"
  RESTORED="$RESTORE_STAGING/$(basename "$JENKINS_HOME")"
  if [[ -d "$RESTORED" ]]; then
    mv "$JENKINS_HOME" "$BACKUP_ROOT/failed-home-$STAMP" || true
    mv "$RESTORED" "$JENKINS_HOME"
    chown -R jenkins:jenkins "$JENKINS_HOME" || true
  fi
  apt-get install --allow-downgrades -y "jenkins=$OLD_VERSION" || true
  systemctl start jenkins || true
  echo "Recovery attempted. Inspect: journalctl -u jenkins and $LOG"
  fail "Jenkins did not pass post-upgrade health check. Recovery attempted."
fi

NEW_VERSION="$(dpkg-query -W -f='${Version}' jenkins)"
SUMMARY+="Updated Jenkins package: $NEW_VERSION\nHealth check: passed\n"
SUCCESS=1
echo "[$(date -Is)] Maintenance completed successfully. Jenkins version=$NEW_VERSION"
