#!/usr/bin/env bash

set -euo pipefail

ZNS_DEV="${ZNS_DEV:-/dev/nvme0n1}"
META_DEV="${META_DEV:-/dev/vdb}"
OUTPUT="${OUTPUT:-mixed_benchmark_results.csv}"

TESTFILE_SIZE="${TESTFILE_SIZE:-64M}"
RUNTIME="${RUNTIME:-20}"
REPEATS="${REPEATS:-1}"

BLOCK_SIZES=("4k" "64k" "128k")
QUEUE_DEPTHS=("1" "16")
FILESYSTEMS=("f2fs" "btrfs" "xfs" "zlfs")

FIO_OUT="/tmp/fio_output.json"
ZONE_SNAP_BEFORE="/tmp/zone_snap_before.txt"
ZONE_SNAP_AFTER="/tmp/zone_snap_after.txt"

MOUNT_DIR_OVERRIDE=""

WORKLOADS=(
    "seq_write        write       -"
    "seq_read         read        -"
    "rand_write       randwrite   -"
    "rand_read        randread    -"
    "seq_mixed_70r    rw          70"
    "seq_mixed_50r    rw          50"
    "rand_mixed_70r   randrw      70"
    "rand_mixed_50r   randrw      50"
    "rand_mixed_30r   randrw      30"
)

log() {
    echo "[$(date +%H:%M:%S)] $*"
}

usage() {
    echo "Usage: $0 <filesystem> [options]"
    echo "  filesystem: f2fs | btrfs | xfs | zlfs"
    echo
    echo "Options:"
    echo "  --mount-dir DIR    Use DIR as the mounted filesystem path (default: /mnt/<fs>)"
    echo
    echo "Workloads run:"
    echo "  seq_write        Sequential writes"
    echo "  seq_read         Sequential reads"
    echo "  rand_write       Random writes"
    echo "  rand_read        Random reads"
    echo "  seq_mixed_70r    Sequential 70% read / 30% write"
    echo "  seq_mixed_50r    Sequential 50% read / 50% write"
    echo "  rand_mixed_70r   Random 70% read / 30% write"
    echo "  rand_mixed_50r   Random 50% read / 50% write"
    echo "  rand_mixed_30r   Random 30% read / 70% write"
    echo
    echo "Example:"
    echo "  sudo ZNS_DEV=/dev/nvme0n1 META_DEV=/dev/vdb OUTPUT=mixed_zlfs.csv \\"
    echo "    $0 zlfs --mount-dir /mnt/ZNS"
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
    [[ "$(id -u)" -eq 0 ]] || { echo "ERROR: run as root"; exit 1; }
}

check_devices() {
    [[ -b "$ZNS_DEV" ]] || { echo "ERROR: missing ZNS device $ZNS_DEV"; exit 1; }
    [[ -b "$META_DEV" ]] || { echo "ERROR: missing metadata device $META_DEV"; exit 1; }
}

dev_base() { basename "$1"; }

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

parse_bw()       { jq '.jobs[0].read.bw + .jobs[0].write.bw' "$FIO_OUT"; }
parse_iops()     { jq '.jobs[0].read.iops + .jobs[0].write.iops' "$FIO_OUT"; }
parse_lat_mean() { jq '.jobs[0].read.lat_ns.mean + .jobs[0].write.lat_ns.mean' "$FIO_OUT"; }
parse_app_bytes_w() { jq '.jobs[0].write.io_bytes' "$FIO_OUT"; }

parse_clat_pct() {
    local key
    key=$(printf "%.6f" "$1")
    jq "((.jobs[0].read.clat_ns.percentile  // {}) | .[\"$key\"] // 0) +
        ((.jobs[0].write.clat_ns.percentile // {}) | .[\"$key\"] // 0)" "$FIO_OUT"
}

parse_actual_rwmix() {
    local total_read total_write
    total_read=$(jq '.jobs[0].read.io_bytes' "$FIO_OUT")
    total_write=$(jq '.jobs[0].write.io_bytes' "$FIO_OUT")
    local total=$(( total_read + total_write ))
    if (( total > 0 )); then
        echo "scale=1; 100 * $total_read / $total" | bc
    else
        echo "N/A"
    fi
}

# setup_f2fs() {
#     log "Formatting F2FS"
#     mkdir -p /mnt/f2fs
#     umount /mnt/f2fs 2>/dev/null || true
#     wipe_devices
#     mkfs.f2fs -f -m -c "$ZNS_DEV" "$META_DEV" >/dev/null
#     mount -t f2fs "$META_DEV" /mnt/f2fs
# }
# teardown_f2fs() {
#     rm -rf /mnt/f2fs/testfile /mnt/f2fs/metadir 2>/dev/null || true
#     umount /mnt/f2fs 2>/dev/null || true
# }

# setup_btrfs() {
#     log "Formatting Btrfs"
#     mkdir -p /mnt/btrfs
#     umount /mnt/btrfs 2>/dev/null || true
#     wipe_devices
#     mkfs.btrfs -f "$ZNS_DEV" >/dev/null
#     mount -t btrfs "$ZNS_DEV" /mnt/btrfs
# }
# teardown_btrfs() {
#     rm -rf /mnt/btrfs/testfile /mnt/btrfs/metadir 2>/dev/null || true
#     umount /mnt/btrfs 2>/dev/null || true
# }

# setup_xfs() {
#     log "Formatting XFS"
#     mkdir -p /mnt/xfs
#     umount /mnt/xfs 2>/dev/null || true
#     wipe_devices
#     command -v mkfs.xfs >/dev/null 2>&1 || { echo "SKIP: mkfs.xfs not installed"; return 1; }
#     mkfs.xfs -f -r rtdev="$ZNS_DEV" "$META_DEV" >/dev/null
#     mount -t xfs "$META_DEV" /mnt/xfs
# }
# teardown_xfs() {
#     rm -rf /mnt/xfs/testfile /mnt/xfs/metadir 2>/dev/null || true
#     umount /mnt/xfs 2>/dev/null || true
# }

# setup_zlfs() {
#     log "Z-LFS setup not implemented in this script."
#     log "Use --skip-setup when Z-LFS is already formatted and mounted."
#     return 1
# }
# teardown_zlfs() {
#     local mount_dir="${MOUNT_DIR_OVERRIDE:-/mnt/zlfs}"
#     sync
#     rm -rf "$mount_dir/testfile" "$mount_dir/metadir" 2>/dev/null || true
#     umount "$mount_dir" 2>/dev/null || true
# }


populate_read_data() {
    local mount_dir=$1
    local filename="$mount_dir/testfile"
    log "Pre-filling $TESTFILE_SIZE for read workload..."
    rm -f "$filename" 2>/dev/null || true
    fio \
        --name=prefill \
        --filename="$filename" \
        --ioengine=libaio \
        --direct=1 \
        --rw=write \
        --bs=128k \
        --iodepth=4 \
        --size="$TESTFILE_SIZE" \
        --numjobs=1 \
        --group_reporting \
        --output=/tmp/fio_prefill.json \
        --output-format=json >/dev/null 2>&1
    sync
    log "Pre-fill done."
}


CURRENT_TEST=0
TOTAL_TESTS=0

run_test() {
    local fs=$1
    local mount_dir=$2
    local workload_name=$3
    local rw=$4
    local rwmixread=$5
    local bs=$6
    local qd=$7
    local run=$8

    (( CURRENT_TEST++ )) || true

    local mix_label="$rwmixread"
    [[ "$rwmixread" == "-" ]] && mix_label="pure"

    printf "  [%d/%d] %-16s bs=%-5s qd=%-3s  mix_read=%s ... " \
        "$CURRENT_TEST" "$TOTAL_TESTS" "$workload_name" "$bs" "$qd" "$mix_label"

    local filename="$mount_dir/testfile"

    if [[ "$rw" == "write" || "$rw" == "randwrite" ]]; then
        rm -f "$filename" 2>/dev/null || true
    fi

    local extra_args=(--size="$TESTFILE_SIZE" --time_based --runtime="$RUNTIME")
    if [[ "$rwmixread" != "-" ]]; then
        extra_args+=(--rwmixread="$rwmixread")
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

    local ACTUAL_READ_PCT
    ACTUAL_READ_PCT=$(parse_actual_rwmix)

    local bw_mb
    bw_mb=$(echo "scale=1; $BW / 1024" | bc)
    printf "done  (BW=%s MB/s  IOPS=%s)\n" "$bw_mb" "$IOPS"

    echo "$fs,$workload_name,$rw,$bs,$qd,$run,$BW,$IOPS,$LAT_MEAN,$LAT_P99,$LAT_P999,$LAT_P9999,$WRITE_AMP,$ZONE_RESETS,$ACTUAL_READ_PCT" >> "$OUTPUT"
}

run_fs_suite() {
    local fs=$1
    local mount_dir="/mnt/$fs"
    [[ -n "$MOUNT_DIR_OVERRIDE" ]] && mount_dir="$MOUNT_DIR_OVERRIDE"

    echo "══════════════════════════════════════════════"
    echo " Filesystem: $fs"
    echo " Mount dir : $mount_dir"
    echo "══════════════════════════════════════════════"

    [[ -d "$mount_dir" ]] || { echo "ERROR: mount directory does not exist: $mount_dir"; exit 1; }
    mountpoint -q "$mount_dir" || { echo "ERROR: $mount_dir is not mounted"; exit 1; }

    TOTAL_TESTS=$(( ${#WORKLOADS[@]} * ${#BLOCK_SIZES[@]} * ${#QUEUE_DEPTHS[@]} * REPEATS ))
    CURRENT_TEST=0
    local suite_start=$SECONDS
    local wl_num=0
    local needs_prefill=0

    for WORKLOAD_DEF in "${WORKLOADS[@]}"; do
        local NAME RW MIX
        NAME=$(awk '{print $1}' <<< "$WORKLOAD_DEF")
        RW=$(awk '{print $2}' <<< "$WORKLOAD_DEF")
        MIX=$(awk '{print $3}' <<< "$WORKLOAD_DEF")

        # Pre-fill once before the first non-pure-write workload
        local is_write_only=0
        [[ "$RW" == "write" || "$RW" == "randwrite" ]] && is_write_only=1

        if [[ "$is_write_only" -eq 0 && "$needs_prefill" -eq 0 ]]; then
            populate_read_data "$mount_dir"
            needs_prefill=1
        fi

        (( wl_num++ )) || true
        local elapsed=$(( SECONDS - suite_start ))
        echo
        echo " Workload ${wl_num}/${#WORKLOADS[@]}: $NAME  (elapsed ${elapsed}s)"

        for BS in "${BLOCK_SIZES[@]}"; do
            for QD in "${QUEUE_DEPTHS[@]}"; do
                for (( RUN=1; RUN<=REPEATS; RUN++ )); do
                    run_test "$fs" "$mount_dir" "$NAME" "$RW" "$MIX" "$BS" "$QD" "$RUN"
                done
            done
        done
    done

    log "Skipping teardown (setup/teardown disabled)"

    echo
    echo " Done with $fs"
    echo
}


[[ $# -lt 1 ]] && { usage; exit 1; }

FS_ARG="$1"
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mount-dir)
            MOUNT_DIR_OVERRIDE="${2:-}"
            [[ -z "$MOUNT_DIR_OVERRIDE" ]] && { echo "ERROR: --mount-dir requires a directory"; exit 1; }
            shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown option '$1'"; usage; exit 1 ;;
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
    echo "ERROR: $ZNS_DEV is not a host-managed zoned device"
    cat "/sys/block/$(dev_base "$ZNS_DEV")/queue/zoned" 2>/dev/null || true
    exit 1
fi

if ! is_non_zoned "$META_DEV"; then
    echo "ERROR: $META_DEV is not a conventional non-zoned block device"
    cat "/sys/block/$(dev_base "$META_DEV")/queue/zoned" 2>/dev/null || true
    exit 1
fi

rm -f "$FIO_OUT" "$ZONE_SNAP_BEFORE" "$ZONE_SNAP_AFTER"

echo "filesystem,workload,fio_rw_mode,block_size,queue_depth,run,bandwidth_KBps,iops,lat_mean_ns,lat_p99_ns,lat_p999_ns,lat_p9999_ns,write_amplification,zone_resets,actual_read_pct" > "$OUTPUT"

echo "Mixed Workload Benchmark Suite"
echo "ZNS device : $ZNS_DEV"
echo "META device: $META_DEV"
echo "Output     : $OUTPUT"
echo "Runtime    : ${RUNTIME}s per test"
echo "File size  : $TESTFILE_SIZE"
echo "Repeats    : $REPEATS"
echo

run_fs_suite "$FS_ARG"

rm -f "$FIO_OUT" "$ZONE_SNAP_BEFORE" "$ZONE_SNAP_AFTER"

echo "Benchmark complete."
echo "Results saved to: $OUTPUT"
