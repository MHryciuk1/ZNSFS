import pandas as pd
import matplotlib.pyplot as plt

# Load CSV
df = pd.read_csv("data/zlfs_results_aggregated.csv")

# Convert block size strings (e.g., "4k") into numbers


def convert_bs(bs):
    if "k" in bs:
        return int(bs.replace("k", "")) * 1024
    if "M" in bs:
        return int(bs.replace("M", "")) * 1024 * 1024
    return int(bs)


df["block_size_bytes"] = df["block_size"].apply(convert_bs)

############################################
# 1. Queue Depth vs Throughput
############################################

subset = df[(df["workload"] == "seq_write") & (df["block_size"] == "128k")]

avg = subset.groupby("queue_depth")["bandwidth_KBps"].mean()

plt.figure()
avg.plot(marker="o")
plt.xlabel("Queue Depth")
plt.ylabel("Bandwidth (KB/s)")
plt.title("Sequential Write Throughput vs Queue Depth")
plt.grid(True)
plt.savefig("queue_depth_vs_throughput.png")

############################################
# 2. Block Size vs Throughput
############################################

subset = df[(df["workload"] == "seq_write") & (df["queue_depth"] == 1)]

avg = subset.groupby("block_size_bytes")["bandwidth_KBps"].mean()

plt.figure()
avg.plot(marker="o")
plt.xlabel("Block Size (bytes)")
plt.ylabel("Bandwidth (KB/s)")
plt.title("Sequential Write Throughput vs Block Size")
plt.grid(True)
plt.savefig("blocksize_vs_throughput.png")

############################################
# 3. Queue Depth vs IOPS
############################################

subset = df[(df["workload"] == "rand_read") & (df["block_size"] == "4k")]

avg = subset.groupby("queue_depth")["iops"].mean()

plt.figure()
avg.plot(marker="o")
plt.xlabel("Queue Depth")
plt.ylabel("IOPS")
plt.title("Random Read IOPS vs Queue Depth")
plt.grid(True)
plt.savefig("queue_depth_vs_iops.png")

print("Graphs generated:")
print(" - queue_depth_vs_throughput.png")
print(" - blocksize_vs_throughput.png")
print(" - queue_depth_vs_iops.png")
