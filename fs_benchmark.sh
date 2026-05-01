#!/usr/bin/env bash

set -euo pipefail

# ---------------- CONFIG ----------------
ZNS_DEV="${ZNS_DEV:-/dev/nvme0n1}"
META_DEV="${META_DEV:-/dev/vdb}"
OUTPUT="${OUTPUT:-zns_benchmark_results.csv}"

TESTFILE_SIZE="${TESTFILE_SIZE:-256M}"
RUNTIME="${RUNTIME:-30}"
REPEATS="${REPEATS:-3}"

# Edit these for shorter/longer sweeps
BLOCK_SIZES=("4k" "16k" "64k" "128k")
QUEUE_DEPTHS=("1" "4" "16" "32")
FILESYSTEMS=("f2fs" "btrfs" "xfs" "zlfs")

FIO_OUT="/tmp/fio_output.json"
ZONE_SNAP_BEFORE="/tmp/zone_snap_before.txt"
ZONE_SNAP_AFTER="/tmp/zone_snap_after.txt"

SKIP_SETUP=0
SKIP_TEARDOWN=0
MOUNT_DIR_OVERRIDE=""

log() {
    echo "[$(date +%H:%M:%S)] $*"
}

usage() {
    echo "Usage: $0 <filesystem> [options]"
    echo "  filesystem: f2fs | btrfs | xfs | zlfs"
    echo
    echo "Options:"
    echo "  --skip-setup       Do not format or mount the filesystem"
    echo "  --skip-teardown    Do not delete testfile or unmount after tests"
    echo "  --mount-dir DIR    Use DIR as the mounted filesystem path"
    echo
    echo "Example:"
    echo "  sudo ZNS_DEV=/dev/nvme0n1 META_DEV=/dev/vdb OUTPUT=zlfs_results.csv $0 zlfs --skip-setup --skip-teardown --mount-dir /mnt/ZNS"
}

require_cmds() {
    local missing=()
    for cmd in fio jq blkzone bc wipefs mountpoint awk paste sed; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: Missing tools: ${missing[*]}"
        echo "Install: sudo apt-get install -y fio jq util-linux bc"
        exit 1
    fi
}

check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "ERROR: run as root"
        exit 1
    fi
}

check_devices() {
    [[ -b "$ZNS_DEV" ]] || { echo "ERROR: missing ZNS device $ZNS_DEV"; exit 1; }

    # META_DEV is only required for filesystems that use it during setup.
    # If --skip-setup is used, do not force META_DEV to exist.
    if [[ "$SKIP_SETUP" -eq 0 ]]; then
        [[ -b "$META_DEV" ]] || { echo "ERROR: missing metadata device $META_DEV"; exit 1; }
    fi
}

dev_base() {
    basename "$1"
}

is_zoned_host_managed() {
    [[ "$(cat /sys/block/"$(dev_base "$1")"/queue/zoned 2>/dev/null || echo none)" == "host-managed" ]]
}

is_non_zoned() {
    [[ "$(cat /sys/block/"$(dev_base "$1")"/queue/zoned 2>/dev/null || echo none)" == "none" ]]
}

wipe_devices() {
    wipefs -a "$META_DEV" >/dev/null 2>&1 || true
    blkzone reset "$ZNS_DEV" >/dev/null 2>&1 || true
    wipefs -a "$ZNS_DEV" >/dev/null 2>&1 || true
}

get_sectors_written() {
    awk '{print $7}' "/sys/block/$(dev_base "$ZNS_DEV")/stat"
}

snapshot_zone_wptrs() {
    blkzone report "$ZNS_DEV" 2>/dev/null \
        | sed -n 's/.*wptr \(0x[0-9a-fA-F]*\).*/\1/p' \
        | while read -r hex; do printf "%d\n" "$hex"; done > "$1"
}

count_zone_resets() {
    paste "$ZONE_SNAP_BEFORE" "$ZONE_SNAP_AFTER" 2>/dev/null \
        | awk '$2 < $1 {r++} END {print r+0}'
}

parse_bw() {
    jq '.jobs[0].read.bw + .jobs[0].write.bw' "$FIO_OUT"
}

parse_iops() {
    jq '.jobs[0].read.iops + .jobs[0].write.iops' "$FIO_OUT"
}

parse_lat_mean() {
    jq '.jobs[0].read.lat_ns.mean + .jobs[0].write.lat_ns.mean' "$FIO_OUT"
}

parse_app_bytes_w() {
    jq '.jobs[0].write.io_bytes' "$FIO_OUT"
}

parse_clat_pct() {
    local key
    key=$(printf "%.6f" "$1")

    jq "((.jobs[0].read.clat_ns.percentile  // {}) | .[\"$key\"] // 0) +
        ((.jobs[0].write.clat_ns.percentile // {}) | .[\"$key\"] // 0)" "$FIO_OUT"
}

setup_f2fs() {
    log "Formatting F2FS"
    local mount_dir="/mnt/f2fs"

    mkdir -p "$mount_dir"
    umount "$mount_dir" 2>/dev/null || true

    wipe_devices

    # This is the conventional F2FS-on-ZNS command, not Z-LFS.
    mkfs.f2fs -f -m -c "$ZNS_DEV" "$META_DEV" >/dev/null

    mount -t f2fs "$META_DEV" "$mount_dir"
}

teardown_f2fs() {
    rm -f /mnt/f2fs/testfile 2>/dev/null || true
    umount /mnt/f2fs 2>/dev/null || true
}

setup_btrfs() {
    log "Formatting Btrfs"
    local mount_dir="/mnt/btrfs"

    mkdir -p "$mount_dir"
    umount "$mount_dir" 2>/dev/null || true

    wipe_devices

   mkfs.btrfs -f "$ZNS_DEV" >/dev/null
    mount -t btrfs "$ZNS_DEV" "$mount_dir"
}

teardown_btrfs() {
    rm -f /mnt/btrfs/testfile 2>/dev/null || true
    umount /mnt/btrfs 2>/dev/null || true
}

setup_xfs() {
    log "Formatting XFS"
    local mount_dir="/mnt/xfs"

    mkdir -p "$mount_dir"
    umount "$mount_dir" 2>/dev/null || true

    wipe_devices

    if ! command -v mkfs.xfs >/dev/null 2>&1; then
        echo "SKIP: mkfs.xfs not installed"
        return 1
    fi

    mkfs.xfs -f -r rtdev="$ZNS_DEV" "$META_DEV" >/dev/null
    mount -t xfs "$META_DEV" "$mount_dir"
}

teardown_xfs() {
    rm -f /mnt/xfs/testfile 2>/dev/null || true
    umount /mnt/xfs 2>/dev/null || true
}

setup_zlfs() {
    log "Z-LFS setup not implemented in this script."
    log "Use --skip-setup when Z-LFS is already formatted and mounted."
    return 1
}

teardown_zlfs() {
    local mount_dir="/mnt/zlfs"
    if [[ -n "$MOUNT_DIR_OVERRIDE" ]]; then
        mount_dir="$MOUNT_DIR_OVERRIDE"
    fi

    sync
    rm -f "$mount_dir/testfile" 2>/dev/null || true
    umount "$mount_dir" 2>/dev/null || true
}

populate_read_data() {
    local fs=$1
    local mount_dir=$2
    local filename="$mount_dir/testfile"

    log "Pre-filling data for $fs read benchmark"
    rm -f "$filename" 2>/dev/null || true
    sync
     fio \
	--name=prefill \
	 --filename="$filename" \
	 --ioengine=libaio \
         --direct=1 \
	 --rw=write \
         --bs=128k \
         --iodepth=1 \
         --size="$TESTFILE_SIZE" \
	 --numjobs=1 \
	 --group_reporting \
	 --output=/tmp/fio_prefill.json \
	 --output-format=json
         sync
}

run_test() {
    local fs=$1
    local mount_dir=$2
    local workload_name=$3
    local rw=$4
    local bs=$5
    local qd=$6
    local run=$7

    printf "  [%-6s] %-10s bs=%-5s qd=%-3s run=%d\n" "$fs" "$workload_name" "$bs" "$qd" "$run"

    local filename="$mount_dir/testfile"
    local extra_args=(--size="$TESTFILE_SIZE" --time_based --runtime="$RUNTIME")

    # Do not delete the file for read tests; populate_read_data creates it.
    if [[ "$rw" == "write" ]]; then
        rm -f "$filename" 2>/dev/null || true
    fi

    local sectors_before sectors_after
    sectors_before=$(get_sectors_written)
    snapshot_zone_wptrs "$ZONE_SNAP_BEFORE"

    fio \
        --name="$workload_name" \
        --filename="$filename" \
        --ioengine=libaio \
        --direct=1 \
        --rw="$rw" \
        --bs="$bs" \
        --iodepth="$qd" \
        --numjobs=1 \
        --group_reporting \
        --output="$FIO_OUT" \
        --output-format=json \
        "${extra_args[@]}" >/dev/null 2>&1

    sectors_after=$(get_sectors_written)
    snapshot_zone_wptrs "$ZONE_SNAP_AFTER"

    local BW IOPS LAT_MEAN LAT_P99 LAT_P999 LAT_P9999
    BW=$(parse_bw)
    IOPS=$(parse_iops)
    LAT_MEAN=$(parse_lat_mean)
    LAT_P99=$(parse_clat_pct 99)
    LAT_P999=$(parse_clat_pct 99.9)
    LAT_P9999=$(parse_clat_pct 99.99)

    local WRITE_AMP="N/A"
    local app_bytes
    app_bytes=$(parse_app_bytes_w)

    if [[ "$app_bytes" =~ ^[0-9]+$ ]] && (( app_bytes > 0 )); then
        local dev_bytes=$(( (sectors_after - sectors_before) * 512 ))
        WRITE_AMP=$(echo "scale=4; $dev_bytes / $app_bytes" | bc)
    fi

    local ZONE_RESETS
    ZONE_RESETS=$(count_zone_resets)

    echo "$fs,$workload_name,$bs,$qd,$run,$BW,$IOPS,$LAT_MEAN,$LAT_P99,$LAT_P999,$LAT_P9999,$WRITE_AMP,$ZONE_RESETS" >> "$OUTPUT"
}

run_fs_suite() {
    local fs=$1
    local mount_dir="/mnt/$fs"

    if [[ -n "$MOUNT_DIR_OVERRIDE" ]]; then
        mount_dir="$MOUNT_DIR_OVERRIDE"
    fi

    echo "══════════════════════════════════════════════"
    echo " Filesystem: $fs"
    echo " Mount dir : $mount_dir"
    echo "══════════════════════════════════════════════"

    if [[ "$SKIP_SETUP" -eq 0 ]]; then
        if ! "setup_${fs}"; then
            echo "SKIP: setup failed for $fs"
            echo
            return 0
        fi
    else
        log "Skipping setup for $fs"

        if [[ ! -d "$mount_dir" ]]; then
            echo "ERROR: mount directory does not exist: $mount_dir"
            exit 1
        fi

        if ! mountpoint -q "$mount_dir"; then
            echo "ERROR: $mount_dir is not a mount point"
            echo "Mount it first, for example:"
            echo "  sudo mkdir -p $mount_dir"
            echo "  sudo mount -t f2fs /dev/ZNS $mount_dir"
            exit 1
        fi
    fi

    for WORKLOAD in "seq_write write"  "seq_read read"; do
        local NAME="${WORKLOAD%% *}"
        local MODE="${WORKLOAD##* }"

        echo
        echo " Workload: $NAME"

        if [[ "$MODE" == "read" ]]; then
            populate_read_data "$fs" "$mount_dir"
        fi

        for BS in "${BLOCK_SIZES[@]}"; do
            for QD in "${QUEUE_DEPTHS[@]}"; do
                for (( RUN=1; RUN<=REPEATS; RUN++ )); do
                    run_test "$fs" "$mount_dir" "$NAME" "$MODE" "$BS" "$QD" "$RUN"
                done
            done
        done
    done

    if [[ "$SKIP_TEARDOWN" -eq 0 ]]; then
        "teardown_${fs}" || true
    else
        log "Skipping teardown for $fs"
    fi

    echo
    echo " Done with $fs"
    echo
}

# ---------------- ARG PARSING ----------------

if [[ $# -lt 1 ]]; then
    usage
    exit 1
fi

FS_ARG="$1"
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-setup)
            SKIP_SETUP=1
            shift
            ;;
        --skip-teardown)
            SKIP_TEARDOWN=1
            shift
            ;;
        --mount-dir)
            MOUNT_DIR_OVERRIDE="${2:-}"
            if [[ -z "$MOUNT_DIR_OVERRIDE" ]]; then
                echo "ERROR: --mount-dir requires a directory"
                exit 1
            fi
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown option '$1'"
            usage
            exit 1
            ;;
    esac
done

if [[ ! " ${FILESYSTEMS[*]} " =~ " ${FS_ARG} " ]]; then
    echo "ERROR: unknown filesystem '$FS_ARG'. Choose from: ${FILESYSTEMS[*]}"
    exit 1
fi

check_root
require_cmds
check_devices

if ! is_zoned_host_managed "$ZNS_DEV"; then
    echo "ERROR: $ZNS_DEV is not detected as host-managed zoned"
    cat "/sys/block/$(dev_base "$ZNS_DEV")/queue/zoned" 2>/dev/null || true
    exit 1
fi

if [[ "$SKIP_SETUP" -eq 0 ]]; then
    if ! is_non_zoned "$META_DEV"; then
        echo "ERROR: $META_DEV is not a conventional non-zoned block device"
        cat "/sys/block/$(dev_base "$META_DEV")/queue/zoned" 2>/dev/null || true
        exit 1
    fi
fi

rm -f "$FIO_OUT" "$ZONE_SNAP_BEFORE" "$ZONE_SNAP_AFTER"

echo "filesystem,workload,block_size,queue_depth,run,bandwidth_KBps,iops,lat_mean_ns,lat_p99_ns,lat_p999_ns,lat_p9999_ns,write_amplification,zone_resets" > "$OUTPUT"

echo "ZNS Benchmark Suite"
echo "ZNS device : $ZNS_DEV"
echo "META device: $META_DEV"
echo "Output     : $OUTPUT"
echo "Runtime    : $RUNTIME"
echo "Size       : $TESTFILE_SIZE"
echo "Repeats    : $REPEATS"
echo

run_fs_suite "$FS_ARG"

rm -f "$FIO_OUT" "$ZONE_SNAP_BEFORE" "$ZONE_SNAP_AFTER"

echo "Benchmark complete."
echo "Results saved to: $OUTPUT"
