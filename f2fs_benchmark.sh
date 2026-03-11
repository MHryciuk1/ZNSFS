#!/bin/bash

MOUNT="/mnt/f2fs"
TESTFILE="$MOUNT/testfile"
OUTPUT="benchmark_results.csv"

SIZE="1G"
RUNTIME=20
REPEATS=3

BLOCK_SIZES=("4k" "16k" "64k" "128k")
QUEUE_DEPTHS=("1" "4" "16" "32")

WORKLOADS=(
"seq_write write"
"seq_read read"
"rand_read randread"
)

echo "workload,block_size,queue_depth,run,bandwidth_KBps,iops,latency_ns" > $OUTPUT

run_test() {

    WORKLOAD_NAME=$1
    RW=$2
    BS=$3
    QD=$4
    RUN=$5

    echo "Running $WORKLOAD_NAME bs=$BS qd=$QD run=$RUN"

    fio \
    --name=$WORKLOAD_NAME \
    --filename=$TESTFILE \
    --size=$SIZE \
    --time_based \
    --runtime=$RUNTIME \
    --ioengine=libaio \
    --direct=1 \
    --rw=$RW \
    --bs=$BS \
    --iodepth=$QD \
    --numjobs=1 \
    --group_reporting \
    --output=fio_output.json \
    --output-format=json

    BW=$(jq '.jobs[0].read.bw + .jobs[0].write.bw' fio_output.json)
    IOPS=$(jq '.jobs[0].read.iops + .jobs[0].write.iops' fio_output.json)
    LAT=$(jq '.jobs[0].read.lat_ns.mean + .jobs[0].write.lat_ns.mean' fio_output.json)

    echo "$WORKLOAD_NAME,$BS,$QD,$RUN,$BW,$IOPS,$LAT" >> $OUTPUT
}

echo "Starting benchmark suite..."

rm -f $TESTFILE

for WORKLOAD in "${WORKLOADS[@]}"
do
    NAME=$(echo $WORKLOAD | awk '{print $1}')
    MODE=$(echo $WORKLOAD | awk '{print $2}')

    for BS in "${BLOCK_SIZES[@]}"
    do
        for QD in "${QUEUE_DEPTHS[@]}"
        do
            for ((RUN=1; RUN<=REPEATS; RUN++))
            do
                run_test $NAME $MODE $BS $QD $RUN
            done
        done
    done
done

rm -f fio_output.json
rm -f $TESTFILE

echo "Benchmark complete."
echo "Results saved to $OUTPUT"
