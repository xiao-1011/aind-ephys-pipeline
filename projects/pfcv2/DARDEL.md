# NAISS Dardel — cluster reference for ephys pipeline

## Cluster architecture

Dardel is a Cray EX system at PDC (KTH). It has two node types:

- **CPU nodes** (AMD EPYC "Milan"): 256 cores, ~232 GB RAM
- **GPU nodes** (NVIDIA GH200): 128 cores, ~483 GB RAM, 1 GPU per node

All nodes run SUSE Linux. The filesystem is Lustre (`/cfs/klemming`).

## Partitions

Checked via `sinfo` on 2026-03-31:

| Partition | Nodes | Cores/node | RAM/node | Max walltime | Allocation mode |
|-----------|-------|------------|----------|--------------|-----------------|
| **main**  | 988   | 256        | ~232 GB  | 1 day        | Whole-node (exclusive) |
| **shared**| 96    | 256        | ~232 GB  | 7 days       | Per-core (shared) |
| **memory**| 302   | 256        | ~483 GB  | 1 day        | Whole-node |
| **gpu**   | 62    | 128        | ~483 GB  | 1 day        | Whole-node |
| **gpugh** | 62    | 128        | ~483 GB  | 1 day        | Whole-node (GH200 ARM) |

### Whole-node vs shared allocation

On `main`, `memory`, and `gpu`: every job gets an entire node regardless of
requested resources. Requesting 4 cores and 16 GB still blocks the full node
(256 cores, 232 GB). Unused resources are wasted.

On `shared`: multiple jobs share a node. SLURM allocates only the requested
cores and memory, so small jobs don't waste an entire node.

### Implications for the pipeline

- **Compute-heavy processes** (PREPROCESS, SORT, ANALYZE) run on `main` and
  request 230 GB (full node minus OS overhead). Since the node is exclusively
  ours regardless, this lets them use all available RAM.

- **Lightweight processes** (COMPARE, CURATE, NWB_EXPORT) run on `shared`
  with 4 cores / 16 GB. They schedule faster and don't waste whole nodes.

- **GPU sorting** (KS4) runs on `gpugh`. Only ~5-7 nodes are typically
  available (rest are reserved or allocated). This is the bottleneck for
  batch processing.

- **Orchestrator** (Nextflow JVM) runs on `shared` with 2 cores / 8 GB.
  Walltime set to 1 day for single recordings, 7 days for batch runs.

## GH200 nodes (gpugh)

The GH200 nodes are ARM-based (aarch64), not x86_64. This means:

- Standard x86 containers don't run natively — they need `--platform linux/amd64`
  emulation via QEMU, or native ARM builds.
- We use a custom apptainer binary (`bin_gh200/apptainer`) that handles
  the platform translation for KS4's GPU container.
- The `beforeScript` in nextflow.config prepends this binary to `$PATH`.

## SLURM scheduling

### Backfill

SLURM uses priority-based scheduling with backfill. Jobs are ordered by
priority (based on fairshare, age, partition, etc.), but the backfill
scheduler can start lower-priority jobs early if they fit in a gap and will
finish before the next high-priority job needs the node.

**Shorter requested walltimes = more backfill opportunities.** A 1h47m job
is much more likely to be backfilled than a 5h job.

Our time multipliers are calibrated to give 2.3-3.6x headroom over observed
runtimes — tight enough for backfill, generous enough to not hit timeouts.

### Pending reasons

- `Priority` — waiting for higher-priority jobs. Normal, just wait.
- `ReqNodeNotAvail` — nodes are down, reserved, or in maintenance.
  Common on `gpugh` where only 5-7 nodes are available.
- `Resources` — waiting for resources to free up.

## SLURM account limits

Account: `naiss2026-3-127` (checked 2026-04-01)

| Limit | Value |
|-------|-------|
| MaxSubmit per user | 1024 jobs |
| Max concurrent running | unlimited |

For batch processing (50 recordings x 2 probes x ~12 jobs = 1200), `maxForks`
must be set in nextflow.config to keep total submitted jobs under 1024.

## Disk and quota

Filesystem: Lustre at `/cfs/klemming`

| Metric | Value (2026-04-01) |
|--------|-------------------|
| Project quota | 29.3 TB |
| Used | 8.4 TB |
| Free | ~21 TB |

### Per-recording disk budget (107 min, 2 probes, 4 sorters)

| Output | Size per probe |
|--------|---------------|
| preprocessed | 128 GB (dominates, ~92%) |
| sorter_kilosort4 | 6.1 GB |
| sorter_spykingcircus2 | 3.3 GB |
| sorter_tridesclous2 | 912 MB |
| sorter_mountainsort5 | TBD |
| motion | 133 MB |
| **Total per probe** | **~138 GB** |
| **Total per recording (2 probes)** | **~280 GB** |

50 recordings at ~280 GB each = ~14 TB.

`publishDir mode: 'link'` uses hardlinks — work directory can be cleaned
after a successful run without losing results (`nextflow clean`).

## Nextflow cache

Nextflow hashes each task's inputs, script, and container invocation template
to decide whether to reuse cached results (`-resume`). Things that invalidate
the cache:

- Changing `envWhitelist` (adds/removes environment variable forwarding in
  the container `.command.run` template)
- Changing the container image
- Changing the process script
- Changing input files or parameters

Notably, changing `memory`, `time`, `cpus`, or `queue` does **not** invalidate
the cache — these only affect SLURM scheduling, not the task hash.

## Modules and environment

Loaded in `slurm_submit.sh`:

```
ml PDC/24.11
ml miniconda3/25.3.1-1-cpeGNU-24.11
ml apptainer/1.4.0-cpeGNU-24.11
```

Nextflow and Java come from the shared conda environment at:
`/cfs/klemming/projects/supr/dmclab/envs/aind-ephys`
