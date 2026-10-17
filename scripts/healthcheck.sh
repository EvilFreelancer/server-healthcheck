#!/bin/sh
# Fleet health check. One read-only pass over a host, verdicts instead of raw facts.
#
#   ssh <target> sh -s < <server-healthcheck>/scripts/healthcheck.sh
#   sh healthcheck.sh                                               (on the machine itself)
#
# Prints "PASS|WARN|FAIL|SKIP  <what>" lines grouped in "=== section ===" blocks and a
# SUMMARY line at the end. Exit code: 0 = no FAIL (WARN and SKIP allowed), 1 = at least
# one FAIL. Every probe is optional, so the script also runs on busybox (OpenWrt) and
# Synology DSM. Nothing here changes the host.
#
# It reports only what the host can judge on its own. Drift against the frontmatter card
# and "is this stack supposed to run" are the agent's job, see SKILL.md.

export LC_ALL=C LANG=C
# sysfs root of the GPU probes, a fake tree in the tests.
SYS=${HEALTHCHECK_SYSFS:-/sys}

FAILED=0
pass() { printf 'PASS  %s\n' "$1"; }
warn() { printf 'WARN  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAILED=1; }
skip() { printf 'SKIP  %s\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

SUDO=""
if [ "$(id -u 2>/dev/null)" != 0 ] && have sudo && sudo -n true 2>/dev/null; then SUDO="sudo -n"; fi
[ "$(id -u 2>/dev/null)" = 0 ] && SUDO=""

echo "=== identity ==="
pass "host $(hostname 2>/dev/null || uname -n 2>/dev/null) at $(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null)"
UP=$(uptime 2>/dev/null | sed 's/.*up //; s/,.*load.*//; s/,[[:space:]]*[0-9]* user.*//')
pass "uptime ${UP:-unknown}"
# A box up for minutes after an unplanned event needs the warm-up rule in SKILL.md.
UPSEC=$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null)
if [ -n "$UPSEC" ] && [ "$UPSEC" -lt 900 ]; then
  warn "booted less than 15 min ago - services may still be warming up, do not call them dead yet"
fi
if have last; then
  # Line 1 is the running boot, line 2 is the one before it. "crash" there means the
  # host went down without a clean shutdown, which is what a power event looks like.
  TOTAL=$(last -x reboot shutdown 2>/dev/null | grep -c 'crash')
  if last -x reboot 2>/dev/null | sed -n 2p | grep -q 'crash'; then
    warn "this boot follows an unclean shutdown ($TOTAL in the recorded history) - power event"
  else
    pass "previous shutdown was clean ($TOTAL unclean in the recorded history)"
  fi
else
  skip "last(1) absent, cannot read boot history"
fi

echo "=== clock ==="
if have timedatectl; then
  SYNC=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
  case "$SYNC" in
    yes) pass "NTP synchronised" ;;
    no)  warn "NTP NOT synchronised - clock may have drifted across the power event" ;;
    *)   skip "timedatectl gave no NTPSynchronized value" ;;
  esac
elif have ntpd || have chronyd; then
  pass "ntp daemon present (no timedatectl to confirm sync)"
else
  skip "no time sync tooling found"
fi

echo "=== services ==="
if have systemctl; then
  # --plain drops the status bullet that would otherwise be the first column.
  FAILED_UNITS=$(systemctl --failed --no-legend --no-pager --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
  if [ -n "$FAILED_UNITS" ]; then
    fail "failed systemd units: $FAILED_UNITS"
  else
    pass "no failed systemd units"
  fi
else
  skip "no systemd on this host"
fi

echo "=== storage ==="
# Read-only roots are normal on OpenWrt (/rom) and Synology, so only rw mounts are judged.
# busybox df has no -x, so the filtering goes through /proc/mounts: only writable
# mounts on a real filesystem are judged. A 100% /rom on OpenWrt is by design.
real_mounts() {
  # Container rootfs overlays live under the docker/containerd data roots and are not
  # storage of their own; measuring them would print dozens of duplicate lines.
  awk '$3 ~ /^(ext[234]|xfs|btrfs|f2fs|ubifs|jffs2|vfat|zfs|overlay)$/ &&
       $4 !~ /(^|,)ro(,|$)/ &&
       $2 !~ /(\/docker\/|\/containerd\/|^\/var\/lib\/|^\/run\/|^\/snap\/)/ {print $2}' \
    /proc/mounts 2>/dev/null | sort -u
}
DISK_FAIL=0
for MNT in $(real_mounts); do
  USE=$(df -P "$MNT" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
  [ -n "$USE" ] || continue
  if [ "$USE" -ge 95 ] 2>/dev/null; then fail "disk $MNT at $USE%"; DISK_FAIL=1
  elif [ "$USE" -ge 85 ] 2>/dev/null; then warn "disk $MNT at $USE%"
  else pass "disk $MNT at $USE%"
  fi
done
[ -z "$(real_mounts)" ] && skip "no writable disk filesystem found to measure"

RO=$(awk '$4 ~ /(^|,)ro(,|$)/ && $3 ~ /^(ext[234]|xfs|btrfs)$/ {print $2}' /proc/mounts 2>/dev/null | tr '\n' ' ')
if [ -n "$RO" ]; then
  fail "writable filesystem remounted read-only: $RO (I/O errors, check the disk)"
else
  pass "no ext/xfs/btrfs mount flipped to read-only"
fi

if [ -n "$SUDO" ] || [ "$(id -u 2>/dev/null)" = 0 ]; then
  # NVMe errors read "I/O 12 QID 3 timeout, aborting" or "... reset controller"; a bare
  # "timeout" also matched the boot-time "nvme0: Shutdown timeout set to 8 seconds".
  IOERR=$($SUDO dmesg 2>/dev/null | grep -icE 'I/O error|EXT4-fs error|XFS.*error|nvme.*(reset|timeout,)|ata[0-9]+\.[0-9]+: failed')
  if [ "${IOERR:-0}" -gt 0 ]; then
    fail "$IOERR disk/IO error line(s) in the kernel log"
  else
    pass "no disk or I/O errors in the kernel log"
  fi
else
  skip "dmesg needs root here, disk errors not checked"
fi

echo "=== memory ==="
if [ -n "$SUDO" ] || [ "$(id -u 2>/dev/null)" = 0 ]; then
  OOM=$($SUDO dmesg 2>/dev/null | grep -ci 'Out of memory: Killed process')
  if [ "${OOM:-0}" -gt 0 ]; then fail "$OOM OOM kill(s) since boot"; else pass "no OOM kills since boot"; fi
else
  skip "dmesg needs root here, OOM kills not checked"
fi

echo "=== docker ==="
if ! have docker; then
  skip "no docker on this host"
elif ! docker info >/dev/null 2>&1; then
  fail "docker is installed but the daemon does not answer"
else
  pass "docker daemon answers ($(docker version --format '{{.Server.Version}}' 2>/dev/null))"

  # A container that is down only matters if it was supposed to stay up. A one-shot with
  # restart policy "no" that exited 0 months ago is litter, not an outage.
  DOWN=""; ONESHOT=""; ODD=""
  for c in $(docker ps -aq --filter status=exited --filter status=dead --filter status=restarting 2>/dev/null); do
    N=$(docker inspect "$c" --format '{{.Name}}' 2>/dev/null | sed 's|^/||')
    ST=$(docker inspect "$c" --format '{{.State.Status}}' 2>/dev/null)
    POL=$(docker inspect "$c" --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null)
    EC=$(docker inspect "$c" --format '{{.State.ExitCode}}' 2>/dev/null)
    case "$ST:$POL" in
      restarting:*|dead:*)  DOWN="$DOWN $N($ST)" ;;
      exited:no|exited:)    if [ "${EC:-0}" = 0 ]; then ONESHOT="$ONESHOT $N"
                            else ODD="$ODD $N(exit $EC)"; fi ;;
      exited:*)             DOWN="$DOWN $N(exit $EC, policy $POL)" ;;
    esac
  done
  if [ -n "$DOWN" ]; then fail "containers that should be running are down:$DOWN"; fi
  if [ -n "$ODD" ]; then warn "one-shot container(s) exited with an error:$ODD"; fi
  if [ -n "$ONESHOT" ]; then skip "one-shot container(s) left over, exit 0, policy no:$ONESHOT"; fi
  if [ -z "$DOWN$ODD$ONESHOT" ]; then pass "no exited, dead or restarting containers"; fi

  UNHEALTHY=$(docker ps --filter health=unhealthy --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')
  if [ -n "$UNHEALTHY" ]; then fail "containers reporting unhealthy: $UNHEALTHY"; else pass "no container reports unhealthy"; fi

  # A container that keeps restarting looks "Up" between crashes.
  LOOP=""
  for c in $(docker ps -q 2>/dev/null); do
    N=$(docker inspect "$c" --format '{{.Name}}' 2>/dev/null | sed 's|^/||')
    R=$(docker inspect "$c" --format '{{.RestartCount}}' 2>/dev/null)
    [ "${R:-0}" -gt 0 ] 2>/dev/null && LOOP="$LOOP $N=$R"
  done
  if [ -n "$LOOP" ]; then warn "containers with a non-zero restart count:$LOOP"; else pass "every running container started once"; fi

  # A field trap after a power cut: docker created containers before dhcpcd wrote resolv.conf,
  # so they came up "Up" with no nameserver at all.
  DNSDEAD=""
  for n in $(docker ps --format '{{.Names}}' 2>/dev/null); do
    docker exec "$n" cat /etc/resolv.conf 2>/dev/null | grep -q 'NO EXTERNAL NAMESERVERS' && DNSDEAD="$DNSDEAD $n"
  done
  if [ -n "$DNSDEAD" ]; then
    fail "containers with no resolver (docker/dhcpcd boot race):$DNSDEAD"
  else
    pass "every running container has a resolver"
  fi

  # Published port with nothing listening behind it.
  LISTEN=$( { ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null; } | awk '{print $4}' | sed 's/.*://' | sort -u)
  DEAD_PORTS=""
  for p in $(docker ps --format '{{.Ports}}' 2>/dev/null | tr ',' '\n' \
             | sed -n 's/.*:\([0-9][0-9]*\)->.*/\1/p' | sort -u); do
    printf '%s\n' "$LISTEN" | grep -qx "$p" || DEAD_PORTS="$DEAD_PORTS $p"
  done
  if [ -n "$DEAD_PORTS" ]; then
    fail "published port(s) with no listener:$DEAD_PORTS"
  else
    pass "every published port has a listener"
  fi
fi

echo "=== gpu ==="
# NVIDIA display controllers on the PCI bus, from sysfs: needs neither pciutils nor the driver.
# The kernel driver bound to each says whether the module or only the tools are missing.
PCI=0
PCI_DRV=""
for d in $SYS/bus/pci/devices/*; do
  [ -r "$d/vendor" ] && [ -r "$d/class" ] || continue
  case "$(cat "$d/vendor"):$(cat "$d/class")" in
    0x10de:0x03*)
      PCI=$((PCI + 1))
      DRV=""
      [ -e "$d/driver" ] && DRV=$(basename "$(readlink -f "$d/driver")")
      case " $PCI_DRV " in *" ${DRV:-none} "*) ;; *) PCI_DRV="$PCI_DRV ${DRV:-none}" ;; esac
      ;;
  esac
done
if ! have nvidia-smi; then
  if [ "$PCI" -gt 0 ]; then
    fail "$PCI NVIDIA GPU(s) on the PCI bus but no nvidia-smi, kernel driver:${PCI_DRV} (needs the gpu-server-setup skill)"
  else
    skip "no nvidia-smi on this host"
  fi
elif ! nvidia-smi -L >/dev/null 2>&1; then
  fail "nvidia-smi does not answer (driver/module mismatch, needs the gpu-server-setup skill)"
else
  NG=$(nvidia-smi -L 2>/dev/null | grep -c '^GPU')
  if [ "$PCI" -gt 0 ] && [ "$NG" -ne "$PCI" ]; then
    fail "GPU count mismatch: PCI bus=$PCI, nvidia-smi=$NG (a card fell off the bus or is not driven)"
  else
    pass "nvidia-smi sees $NG GPU(s), driver $(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)"
  fi

  ECC=$(nvidia-smi --query-gpu=ecc.errors.uncorrected.volatile.total --format=csv,noheader 2>/dev/null \
        | grep -vE '^\[?N/A|^0$' | tr '\n' ' ')
  if [ -n "$ECC" ]; then fail "uncorrected ECC errors: $ECC"; else pass "no uncorrected ECC errors"; fi

  if [ -n "$SUDO" ] || [ "$(id -u 2>/dev/null)" = 0 ]; then
    XID=$($SUDO dmesg 2>/dev/null | grep -ci 'NVRM.*Xid')
    if [ "${XID:-0}" -gt 0 ]; then fail "$XID NVRM Xid error(s) in the kernel log"; else pass "no NVRM Xid errors"; fi
  else
    skip "dmesg needs root here, Xid errors not checked"
  fi
fi

# Discrete Intel GPUs (Arc, Battlemage): Intel display controllers off bus 00, where the
# integrated one always sits. Each needs a bound i915 or xe driver and a render node,
# otherwise containers get no GPU.
INTEL=0
INTEL_BAD=""
INTEL_DRV=""
for d in $SYS/bus/pci/devices/*; do
  [ -r "$d/vendor" ] && [ -r "$d/class" ] || continue
  case "$(cat "$d/vendor"):$(cat "$d/class")" in 0x8086:0x03*) ;; *) continue ;; esac
  DEV=${d##*/}
  case "$DEV" in *:00:*) continue ;; esac
  INTEL=$((INTEL + 1))
  DRV=""
  [ -e "$d/driver" ] && DRV=$(basename "$(readlink -f "$d/driver")")
  case "$DRV" in
    i915|xe) INTEL_DRV=$DRV ;;
    *) INTEL_BAD="$INTEL_BAD $DEV(no i915/xe driver)"; continue ;;
  esac
  ls -d "$d"/drm/renderD* >/dev/null 2>&1 || INTEL_BAD="$INTEL_BAD $DEV(no render node)"
done
if [ "$INTEL" -gt 0 ]; then
  if [ -n "$INTEL_BAD" ]; then
    fail "Intel discrete GPU(s) not usable:$INTEL_BAD (needs the gpu-server-setup skill)"
  else
    pass "$INTEL Intel discrete GPU(s) on $INTEL_DRV, every one with a render node"
  fi
fi

# PCIe AER of every GPU. Corrected errors are common; what matters is fatal ones and the
# RATE, so a raw counter is never reported as a fault on its own.
for d in $SYS/bus/pci/devices/*/aer_dev_fatal; do
  [ -f "$d" ] || continue
  DEV=$(basename "$(dirname "$d")")
  case "$(cat "$(dirname "$d")/class" 2>/dev/null)" in 0x030*) ;; *) continue ;; esac
  F=$(awk '/TOTAL_ERR_FATAL/{print $2}' "$d" 2>/dev/null)
  NF=$(awk '/TOTAL_ERR_NONFATAL/{print $2}' "$(dirname "$d")/aer_dev_nonfatal" 2>/dev/null)
  C1=$(awk '/TOTAL_ERR_COR/{print $2}' "$(dirname "$d")/aer_dev_correctable" 2>/dev/null)
  if [ "${F:-0}" -gt 0 ] || [ "${NF:-0}" -gt 0 ] 2>/dev/null; then
    fail "PCIe $DEV: fatal=$F nonfatal=$NF (uncorrected link errors)"
  elif [ "${C1:-0}" -gt 0 ] 2>/dev/null; then
    sleep 10
    C2=$(awk '/TOTAL_ERR_COR/{print $2}' "$(dirname "$d")/aer_dev_correctable" 2>/dev/null)
    D=$((C2 - C1))
    if [ "$D" -gt 0 ]; then
      warn "PCIe $DEV: $C2 corrected errors, still growing (+$D in 10s) - marginal link, check seating/riser"
    else
      pass "PCIe $DEV: $C2 corrected errors, not growing"
    fi
  else
    pass "PCIe $DEV: no AER errors"
  fi
done

echo "=== SUMMARY ==="
if [ "$FAILED" -eq 0 ]; then echo "SUMMARY  no FAIL"; else echo "SUMMARY  at least one FAIL"; fi
exit "$FAILED"
