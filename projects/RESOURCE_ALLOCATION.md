# Resource Allocation on Dardel (NAISS)

## The problem: wasting allocation on whole-node exclusive jobs

Dardel has two main CPU partitions:

| Partition | Billing model | Limits |
|-----------|--------------|--------|
| `main` | **Whole-node exclusive** — you are charged for 128 core-hours per node-hour regardless of how many cores you use | 128 cores, 230 GB, 24h default |
| `shared` | **Per-core** — you are charged only for the cores you request, for the time you actually use | up to 256 cores, up to 111 GB, up to 7 days |

The routing rule (from the [nf-core PDC config](https://nf-co.re/configs/pdc_kth/)):

```groovy
if (task.time <= 7.d && task.memory <= 111.GB && task.cpus <= 256) {
    slurm_opts << "-p shared"
}
```

**We were sending nearly every process to `main`**, requesting 128 CPUs and 230 GB even for tasks that needed 4 cores and 1 GB of memory. This meant:

- `ADVANCED_CURATE` (30 seconds, 1-5 GB RSS) was reserving a full 128-core node
- `SORT_TDC2` (5 minutes, 18-21 GB RSS) was reserving a full 128-core node
- `ANALYZE_LUPIN` (17 minutes, 26 GB RSS) was reserving a full 128-core node

For multishank with 4 shanks, the downstream processes fan out per-shank, so each shank gets its own node. That's 4 nodes x N processes, each charged at 128 core-hours per node-hour.

A second benefit of `shared`: **generous time limits cost nothing extra**. On `main`, a 5-hour time limit means reserving (and paying for) a full node for 5 hours even if the job finishes in 30 minutes. On `shared`, you only pay for actual runtime. This lets us give slow sorters (Lupin, SC2) much larger time limits without wasting allocation, solving timeout issues.

## How we measured actual resource usage

Nextflow's trace file records `peak_rss` (peak resident set size) for every completed task. After running the multishank pipeline on a 4-shank NP2 recording (71 minutes, subject 1005256), we extracted peak RSS and CPU utilization from the trace:

```
cat logs/*_trace.txt
```

Key columns: `name`, `peak_rss`, `%cpu`, `realtime`.

Note: `peak_rss` can include memory-mapped file pages (SpikeInterface memory-maps binary recordings). The `peak_vmem` column is much larger (often >1 TB) due to mmap. What matters for SLURM memory limits is RSS.

## Measured peak RSS (multishank, per-shank, 4-shank NP2, 71 min)

| Process | Peak RSS | CPU % (cores active) | Typical runtime | Partition |
|---------|----------|---------------------|-----------------|-----------|
| PREPROCESS | 149 GB | 8660% (~87 cores) | 15 min | main |
| SORT_KS4 | 13-16 GB | 4590-5140% (~46 cores) | 11-22 min | gpugh (GPU) |
| SORT_TDC2 | 18-21 GB | 1027-1154% (~11 cores) | 4-5 min | **shared** |
| SORT_MS5 | 9-30 GB | 4248-4885% (~45 cores) | 15-35 min | **shared** |
| SORT_LUPIN | 52 GB* | 1435% (~14 cores) | 24 min-3h+ | **shared** |
| SORT_SC2 | 65-116 GB | 666-1272% (~13 cores) | 12 min-2h+ | main |
| ANALYZE | 17-319 GB | 1734-4042% (~30 cores) | 3-22 min | main |
| ANALYZE_LUPIN | 26 GB | 3863% (~39 cores) | 17 min | **shared** |
| ADVANCED_CURATE | 1-5 GB | ~1 core | 25-45 sec | **shared** |
| ADV_CURATE_LPN | 6 GB | ~1 core | 50 sec-2 min | **shared** |
| COMPARE | 1 GB | ~1 core | 15-18 sec | shared (was already) |
| COMPARE_CLEAN | 0.4-0.6 GB | ~1 core | 12-14 sec | shared (was already) |
| CONSENSUS_DELTA | 83-85 MB | ~1 core | 1-5 sec | shared (was already) |
| CURATE | 45-48 MB | ~1 core | 5 sec | shared (was already) |

*Lupin RSS measured from the one shank that completed quickly (shank2). The slow shanks timed out before we could measure.

## Why each process is assigned to its partition

### Processes on `main` (whole-node exclusive)

These processes genuinely need >111 GB memory or benefit from having all 128 cores:

- **PREPROCESS** (128 cores, 230 GB): Measured 149 GB peak RSS with 4 shanks running in parallel. The parallel shank processing (4 x 32 cores) uses most of the node. 149 GB > 111 GB shared limit.

- **SORT_SC2** (128 cores, 230 GB): SpykingCircus2 hit 116 GB RSS on one shank (shank1, which had more detected spikes). This exceeds the 111 GB shared limit. Other shanks were 65-93 GB and would fit on shared, but we can't predict per-shank memory in advance.

- **ANALYZE** (128 cores, 230 GB): The analysis step re-loads the full preprocessed recording plus all sorting results to compute waveforms, templates, quality metrics, etc. KiloSort4 analysis peaked at **319 GB** RSS (the KS4 sorting output is large). Other sorters' analyses were lower (17-211 GB) but KS4 analysis alone forces this onto `main`. Since all sorters use the same ANALYZE process definition, they all go to `main`.

### Processes on `shared` (per-core billing)

These processes fit comfortably under 111 GB and don't need 128 cores:

- **SORT_TDC2** (16 cores, 32 GB): Only uses ~11 cores and 18-21 GB. Very fast (4-5 min). The most wasteful process on main — a full node for 5 minutes of 11-core work.

- **SORT_MS5** (64 cores, 64 GB): Uses ~45 cores and 9-30 GB. Requesting 64 cores matches actual usage. Well under 111 GB.

- **SORT_LUPIN** (32 cores, 96 GB): Uses ~14 cores and ~52 GB. The template-matching phase is slow but not CPU-bound. With 5x time multiplier on shared, the generous limit costs nothing extra (pay for 32 cores x actual runtime, not 32 cores x time limit).

- **ANALYZE_LUPIN** (32 cores, 64 GB): Uses ~39 cores and 26 GB. Lupin analysis is lighter than other sorters because the Lupin analyzer stores data differently.

- **ADVANCED_CURATE** (4 cores, 8 GB): Loads a SortingAnalyzer (~1-5 GB for per-shank data), runs UnitRefine ML classifier, computes auto-merge. Single-threaded ML inference. Was the single most wasteful allocation: a full 128-core node for 30 seconds of single-threaded work.

- **ADV_CURATE_LPN** (4 cores, 8 GB): Same as ADVANCED_CURATE but for Lupin output. Same resource profile.

### Processes on `gpugh` (GPU)

- **SORT_KS4** (16 cores, 64 GB, 1 GPU): Needs a GPU. The `gpugh` partition is exclusive — every job gets a full GPU node (4 GPUs) even though KS4 only uses 1 GPU. This is a known inefficiency (see `pfcv2/TODO.md` for multi-GPU optimization plans).

## Measured peak RSS (pfcv2, full probe, 384 channels NP1, 107 min)

From trace of run 19177673 on subject 999770 (2 probes: imec0, imec1).

| Process | Peak RSS | CPU % (cores active) | Typical runtime | Partition |
|---------|----------|---------------------|-----------------|-----------|
| PREPROCESS | ~150 GB | ~87 cores | 30 min | main |
| SORT_KS4 | — | GPU | 43 min | gpugh (GPU) |
| SORT_TDC2 | ~80 GB* | ~11 cores | 72 min | **shared** |
| SORT_MS5 | 47-53 GB | 3304-3718% (~35 cores) | 2h 25-35 min | main** |
| SORT_SC2 | — (timed out) | — | — | main |
| SORT_LUPIN | 98-110 GB | 726-757% (~7 cores) | 2h 40-49 min | main |
| ANALYZE (KS4) | 355-391 GB | 1106-1365% (~12 cores) | 1h 7 min | main |
| ANALYZE (SC2) | 283-299 GB | 1102-1352% (~12 cores) | 53-62 min | main |
| ANALYZE (TDC2) | 131 GB | 830% (~8 cores) | 39 min | main |
| ANALYZE (MS5) | 26-37 GB | 780-1030% (~9 cores) | 18-19 min | main |
| ANALYZE_LUPIN | 69-77 GB | 2261-2390% (~23 cores) | 57-78 min | **shared** |
| ADVANCED_CURATE | 1-11 GB | ~1 core | 30-100 sec | **shared** |
| ADV_CURATE_LPN | 12-13 GB | ~1 core | 1-2 min | **shared** |

*TDC2 was cached in this trace; estimate based on 4x multishank per-shank measurement.
**SORT_MS5 fits on shared (53 GB < 111 GB) but is a candidate for removal (see below).

### Key observations from pfcv2 trace

1. **SORT_LUPIN** uses 98-110 GB on full probe — right at the 111 GB shared limit. Too risky to move to shared; stays on main.

2. **SORT_MS5** uses only 47-53 GB — could go to shared. However, MS5 is a candidate for removal from the pipeline entirely due to poor sorting quality compared to other sorters.

3. **ANALYZE** memory varies enormously by sorter: KS4 analysis uses 391 GB (!) while MS5 analysis uses only 37 GB. Since they share one process definition, all go to main. The KS4 analysis memory is dominated by waveform extraction from the large KS4 sorting output.

4. **ANALYZE_LUPIN** uses 69-77 GB — comfortably under 111 GB, moved to shared (32 cores, 96 GB).

5. **SORT_SC2** timed out and never produced trace data. Based on multishank measurements (65-116 GB per shank), full-probe SC2 likely exceeds 111 GB. Stays on main.

## pfcv2 vs multishank: current partition assignments

### pfcv2 (full probe, 384 channels)

| Process | Queue | CPUs | Memory | Measured RSS |
|---------|-------|------|--------|-------------|
| PREPROCESS | main | 128 | 230 GB | ~150 GB |
| SORT_KS4 | gpugh | 16 | 64 GB | GPU |
| SORT_TDC2 | **shared** | 32 | 96 GB | ~80 GB |
| SORT_SC2 | main | 128 | 230 GB | no data (timed out) |
| SORT_MS5 | main | 128 | 230 GB | 47-53 GB (removal candidate) |
| SORT_LUPIN | main | 128 | 230 GB | 98-110 GB (too close to 111 GB) |
| ANALYZE | main | 128 | 230 GB | 26-391 GB (KS4 drives this) |
| ANALYZE_LUPIN | **shared** | 32 | 96 GB | 69-77 GB |
| ADVANCED_CURATE | **shared** | 4 | 16 GB | 1-11 GB |
| ADV_CURATE_LPN | **shared** | 4 | 16 GB | 12-13 GB |

### multishank (per-shank, ~96 channels)

| Process | Queue | CPUs | Memory | Measured RSS |
|---------|-------|------|--------|-------------|
| PREPROCESS | main | 128 | 230 GB | 149 GB |
| SORT_KS4 | gpugh | 16 | 64 GB | 13-16 GB |
| SORT_TDC2 | **shared** | 16 | 32 GB | 18-21 GB |
| SORT_SC2 | main | 128 | 230 GB | 65-116 GB |
| SORT_MS5 | **shared** | 64 | 64 GB | 9-30 GB |
| SORT_LUPIN | **shared** | 32 | 96 GB | 52 GB |
| ANALYZE | main | 128 | 230 GB | 17-319 GB |
| ANALYZE_LUPIN | **shared** | 32 | 64 GB | 26 GB |
| ADVANCED_CURATE | **shared** | 4 | 8 GB | 1-5 GB |
| ADV_CURATE_LPN | **shared** | 4 | 8 GB | 6 GB |

## Estimated cost per run

### How Dardel billing works

The NAISS allocation is **monthly with a half-life decay window**, not a hard total. SLURM uses a fair-share factor: if you've used more than your share, your jobs get lower scheduling priority but are **not blocked**. Past usage decays over time, so priority gradually recovers.

The `projinfo` "Used corehours" counter is cumulative and doesn't reset. The allocation rate (core-hours/month) determines your fair share of the machine.

Note: SLURM's `sacct` reports `AllocCPUS=256` on main queue nodes — this is the logical/hyperthread count (128 physical cores × 2 SMT threads). **Billing uses 128 physical cores, not 256.** PDC docs confirm: "if you request a full node, your project allocation will be charged for use of 128 cores" and "some Dardel system commands display the number of hardware-supported threads rather than the number of physical cores." So 1 node-hour on main = 128 core-hours against your allocation.

### Cost estimate: multishank (1 probe, 4 shanks, 71-min recording)

Using actual runtimes from trace. Billing: main = 128 ch/node-hour, shared = per-core.

| Process | Count | Avg min | Old (ch) | New (ch) | Savings |
|---------|-------|---------|----------|----------|---------|
| PREPROCESS | 1 | 15 | 32 | 32 | — |
| SORT_KS4 | 4 | 16 | GPU | GPU | — |
| SORT_TDC2 | 4 | 5 | 43 | 5 | **-37** |
| SORT_MS5 | 4 | 25 | 213 | 107 | **-107** |
| SORT_SC2 | 4 | 50 | 427 | 427 | — |
| SORT_LUPIN | 4 | 25 | 213 | 53 | **-160** |
| ANALYZE (all) | 20 | 8-18 | 427 | 427 | — |
| ANALYZE_LUPIN | 4 | 17 | 145 | 36 | **-109** |
| ADVANCED_CURATE | 16 | 0.5 | 17 | 1 | **-16** |
| ADV_CURATE_LPN | 4 | 1 | 9 | 0.3 | **-8** |
| **Total (CPU)** | | | **1,526** | **1,088** | **-29%** |

### Per-sorter cost breakdown (multishank, 1 probe, 4 shanks, 71-min recording)

Full end-to-end cost for each sorter across all 4 shanks: SORT + ANALYZE + ADVANCED_CURATE.
From trace 19219639 (subject 1005256, 4-shank NP2). Uses new (optimized) partition assignments.

| Sorter | Sort RSS | Sort runtime (×4) | Sort cost | Analyze RSS | Analyze runtime (×4) | Analyze cost | Curate cost | **Total (ch/probe)** |
|--------|----------|-------------------|-----------|-------------|---------------------|-------------|-------------|---------------------|
| **KS4** | 13-16 GB | 11-22 min | GPU (0 CPU) | 245-319 GB | 13-22 min (main) | 146 | 1 | **147** |
| **TDC2** | 18-21 GB | 4-5 min | 5 (shared) | 17-26 GB | 3-5 min (main) | 34 | 1 | **40** |
| **SC2** | 65-116 GB | 12-66 min | 427 (main) | 99-211 GB | 7-10 min (main) | 68 | 1 | **496** |
| **Lupin** | 52 GB | 24 min-3h+ | 53 (shared)* | 26 GB | 17 min (shared) | 36 | 1 | **90** |
| **MS5** | 9-30 GB | 15-35 min | 107 (shared) | 32-91 GB | 6-7 min (main) | 55 | 1 | **163** |

*Lupin sort cost assumes fast completion (24 min). Slow shanks that time out still cost 32 cores × actual runtime on shared.

Key takeaways:

- **TDC2 is the cheapest** (40 ch) — very fast sorting on shared, light analysis.
- **Lupin is cheap when it completes** (90 ch) — both sort and analysis on shared. But slow shanks can time out and cost more.
- **KS4** (147 ch) — sorting is free (GPU), but analysis is expensive on main (loads huge KS4 waveform data).
- **MS5** (163 ch) — moderate cost, mostly on shared. If sorting quality is poor, this is wasted.
- **SC2 is the most expensive** (496 ch) — sorting can exceed 111 GB (stays on main), and runtimes vary wildly (12 min to 66 min per shank). Some shanks time out entirely.

### Cost estimate: pfcv2 (1 probe, full 384 ch, 107-min recording)

| Process | Count | Avg min | Old (ch) | New (ch) | Savings |
|---------|-------|---------|----------|----------|---------|
| PREPROCESS | 1 | 30 | 64 | 64 | — |
| SORT_KS4 | 1 | 43 | GPU | GPU | — |
| SORT_TDC2 | 1 | 72 | 154 | 38 | **-115** |
| SORT_MS5 | 1 | 137 | 293 | 293 | — |
| SORT_SC2 | 1 | 65 | 139 | 139 | — |
| SORT_LUPIN | 1 | 120 | 256 | 256 | — |
| ANALYZE (all) | 4 | 45 | 384 | 384 | — |
| ANALYZE_LUPIN | 1 | 57 | 122 | 30 | **-91** |
| ADVANCED_CURATE | 4 | 1 | 9 | 0.3 | **-8** |
| ADV_CURATE_LPN | 1 | 1 | 2 | 0.1 | **-2** |
| **Total (CPU)** | | | **1,421** | **1,204** | **-15%** |

For the pfcv2 batch of 30 probes: ~36,000 core-hours (new) vs ~43,000 (old).

### Per-sorter cost breakdown (pfcv2, 1 probe, 107-min recording)

Full end-to-end cost for each sorter: SORT + ANALYZE + ADVANCED_CURATE.
From trace 19177673 (subject 999770, averaged across imec0/imec1).

| Sorter | Sort RSS | Sort runtime | Sort cost | Analyze RSS | Analyze runtime | Analyze cost | Curate cost | **Total (ch/probe)** |
|--------|----------|-------------|-----------|-------------|-----------------|-------------|-------------|---------------------|
| **KS4** | GPU | 43 min | GPU (0 CPU) | 355-391 GB | 63 min (main) | 134 | 0.3 | **135** |
| **TDC2** | ~80 GB | 72 min | 38 (shared) | 131 GB | 39 min (main) | 83 | 0.3 | **121** |
| **SC2** | >111 GB* | 65 min | 139 (main) | 283-299 GB | 58 min (main) | 124 | 0.3 | **263** |
| **Lupin** | 98-110 GB | 2h 45m | 256 (main) | 69-77 GB | 68 min (shared) | 36 | 0.3 | **293** |
| **MS5** | 47-53 GB | 2h 30m | 293 (main) | 26-37 GB | 19 min (main) | 41 | 0.3 | **334** |

*SC2 timed out in this run; RSS estimated from multishank data.

Key takeaways:

- **TDC2 is the cheapest** (121 ch) — fast sorting on shared, moderate analysis on main.
- **KS4 is almost as cheap** (135 ch) because sorting runs on GPU (separate allocation) and only ANALYZE uses CPU.
- **SC2** (263 ch) is moderate. Sorting and analysis are both memory-heavy and must stay on main.
- **Lupin** (293 ch) is expensive mainly due to sorting on main (98-110 GB forces it there). Its analysis is cheap (shared). Lupin produces good results but is slow.
- **MS5 is the most expensive** (334 ch) and produces the worst sorting quality. Strong candidate for removal. Dropping it saves ~334 ch/probe, or ~10,000 ch for the 30-probe batch.

### Strategy: run KS4 first, add sorters incrementally

Given the allocation constraints, the recommended approach is:

1. **Run KS4 for all probes first** — KS4 runs on GPU partition (separate allocation) and produces initial sorting results quickly. The CPU cost is only the ANALYZE + CURATE steps.
2. **Add other sorters incrementally** — run TDC2 next (cheap on shared), then SC2/Lupin as priority recovers.
3. **Consider dropping MS5** — MountainSort5 produced poor results compared to other sorters in our tests. Removing it saves ~585 ch/probe on pfcv2 and ~107 ch/probe on multishank.

## How to check resource usage for future recordings

After any pipeline run, check the Nextflow trace:

```bash
# Look at peak RSS and CPU usage for all completed tasks
column -t -s $'\t' logs/*_trace.txt | less -S

# Or extract just the key columns
awk -F'\t' 'NR==1 || /COMPLETED/ {print $4, $11, $10, $8}' logs/*_trace.txt | column -t
```

If a process on `shared` fails with an out-of-memory error (SLURM exit code 137 or OOM message), increase its memory allocation or move it back to `main`.

If a process on `main` consistently uses <80 GB RSS, consider moving it to `shared` to save allocation.
