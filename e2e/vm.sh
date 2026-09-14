#!/bin/bash
# e2e/vm.sh — Tart VM harness for devseed e2e runs.
#
# Every scenario starts from a throwaway APFS clone of a base VM; the base
# is never booted or mutated. Clones cost ~0 disk until they diverge.
#
#   e2e/vm.sh clone NAME      create NAME from $DEVSEED_E2E_BASE
#   e2e/vm.sh up NAME         boot headless, wait for IP + SSH
#   e2e/vm.sh ip NAME         print the VM's IP
#   e2e/vm.sh ssh NAME [CMD]  run CMD (or a login shell) over SSH
#   e2e/vm.sh push NAME SRC DST   copy a file/dir into the VM (scp -r)
#   e2e/vm.sh down NAME       shut the VM down (graceful, then hard)
#   e2e/vm.sh destroy NAME    stop if needed and delete the VM
#   e2e/vm.sh fresh NAME      destroy + clone + up (one-shot reset)
#
# Environment:
#   DEVSEED_E2E_BASE  base VM to clone            (default: agent-template)
#   DEVSEED_E2E_USER  SSH user inside the VM      (default: admin)
#   DEVSEED_E2E_DISK  grow the clone's disk to N GB before first boot.
#                     The base image leaves ~20 GB free, which a real
#                     config full of GUI casks exhausts partway through
#                     the brew step ("No space left on device").
#
# SSH auth is key-based (BatchMode): the base image must already authorize
# the host's key. The cirruslabs images and agent-template both do.
set -euo pipefail

BASE="${DEVSEED_E2E_BASE:-agent-template}"
VM_USER="${DEVSEED_E2E_USER:-admin}"
DISK_GB="${DEVSEED_E2E_DISK:-}"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)

die() {
  echo "vm.sh: $*" >&2
  exit 1
}

need_name() { [ -n "${1:-}" ] || die "VM name required"; }

vm_exists() { tart list --format json 2>/dev/null | grep -q "\"$1\"" || tart list 2>/dev/null | awk '{print $2}' | grep -qx "$1"; }

vm_running() { tart list 2>/dev/null | awk -v n="$1" '$2 == n {print $NF}' | grep -qx running; }

cmd_clone() {
  need_name "${1:-}"
  vm_exists "$1" && die "VM '$1' already exists (use fresh to reset)"
  tart clone "$BASE" "$1"
  if [ -n "$DISK_GB" ]; then
    # Grow-only, and the guest still has to claim the new space; that
    # happens in cmd_up once SSH is reachable.
    tart set "$1" --disk-size "$DISK_GB"
    echo "resized $1 disk -> ${DISK_GB}G"
  fi
  echo "cloned $BASE -> $1"
}

cmd_up() {
  need_name "${1:-}"
  local name="$1" ip=""
  if ! vm_running "$name"; then
    nohup tart run "$name" --no-graphics >"/tmp/devseed-e2e-$name.log" 2>&1 &
  fi
  for _ in $(seq 1 36); do
    ip="$(tart ip "$name" 2>/dev/null || true)"
    if [ -n "$ip" ] && ssh "${SSH_OPTS[@]}" "$VM_USER@$ip" true 2>/dev/null; then
      if [ -n "$DISK_GB" ]; then
        # A bigger block device is not bigger free space until the APFS
        # container is extended over it.
        ssh "${SSH_OPTS[@]}" "$VM_USER@$ip" \
          'sudo diskutil apfs resizeContainer $(diskutil list | awk "/Apple_APFS/ {print \$NF; exit}") 0' \
          >/dev/null 2>&1 || echo "warning: could not extend the APFS container" >&2
        echo "free space in $name: $(ssh "${SSH_OPTS[@]}" "$VM_USER@$ip" "df -h / | tail -1 | awk '{print \$4}'")"
      fi
      echo "up: $name at $ip"
      return 0
    fi
    sleep 5
  done
  die "VM '$name' did not become SSH-reachable in 3m (log: /tmp/devseed-e2e-$name.log)"
}

cmd_ip() {
  need_name "${1:-}"
  tart ip "$1"
}

cmd_ssh() {
  need_name "${1:-}"
  local name="$1" ip
  shift
  ip="$(tart ip "$name")" || die "no IP for '$name' (is it up?)"
  if [ "$#" -gt 0 ]; then
    # shellcheck disable=SC2029 # client-side expansion is the contract: callers pass a ready remote command
    ssh "${SSH_OPTS[@]}" "$VM_USER@$ip" "$@"
  else
    ssh "${SSH_OPTS[@]}" -t "$VM_USER@$ip"
  fi
}

cmd_push() {
  need_name "${1:-}"
  [ -e "${2:-}" ] || die "push: source '$2' not found"
  [ -n "${3:-}" ] || die "push: destination path required"
  local ip
  ip="$(tart ip "$1")" || die "no IP for '$1' (is it up?)"
  scp "${SSH_OPTS[@]}" -q -r "$2" "$VM_USER@$ip:$3"
}

cmd_down() {
  need_name "${1:-}"
  vm_running "$1" || return 0
  cmd_ssh "$1" "sudo shutdown -h now" 2>/dev/null || true
  for _ in $(seq 1 12); do
    vm_running "$1" || return 0
    sleep 5
  done
  tart stop "$1" 2>/dev/null || true
}

cmd_destroy() {
  need_name "${1:-}"
  vm_exists "$1" || return 0
  cmd_down "$1"
  tart delete "$1"
  echo "destroyed $1"
}

cmd_fresh() {
  need_name "${1:-}"
  cmd_destroy "$1"
  cmd_clone "$1"
  cmd_up "$1"
}

case "${1:-}" in
  clone | up | ip | ssh | push | down | destroy | fresh)
    cmd="$1"
    shift
    "cmd_$cmd" "$@"
    ;;
  *)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
