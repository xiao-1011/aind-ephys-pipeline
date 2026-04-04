# Batch processing checklist (50 recordings)

Checklist for scaling from a single recording to the full batch.
Based on the 999770_day1_1_g0 pilot run (107 min, 2 probes, 5 sorters).

## Before submitting

### Containers

- [ ] Ensure lupin container is built: `ls $NXF_APPTAINER_CACHEDIR/lupin.sif`
      If missing, build on login node: `cd arm-apptainer && bash build-lupin.sh`

### slurm_submit.sh

- [ ] Set `DATA_PATH` to the parent directory containing all recording sessions
      (the pipeline globs `**/*.ap.meta` and discovers all probes automatically)
- [ ] Set walltime to `#SBATCH -t 7-00:00:00` (shared partition max)

### nextflow.config — maxForks

SLURM MaxSubmit = 1024 per user. 50 recordings x 2 probes x ~12 jobs = 1200.
Add `maxForks` to throttle concurrent submissions:

```groovy
withName: PREPROCESS { maxForks = 10 }
withName: SORT_KS4   { maxForks = 6  }   // only ~5-7 GPU nodes on gpugh
withName: SORT_SC2   { maxForks = 10 }
withName: SORT_MS5   { maxForks = 10 }
withName: SORT_TDC2  { maxForks = 10 }
withName: SORT_LUPIN { maxForks = 10 }
withName: ANALYZE    { maxForks = 20 }
withName: ANALYZE_LUPIN { maxForks = 10 }
// COMPARE, CURATE, NWB_EXPORT are fast — can leave uncapped
```

Tune these based on cluster load. The goal is to keep total submitted < 1024.

### Disk space

- [ ] Check quota before starting: `lfs quota -h -p 3252387 /cfs/klemming`
- [ ] Budget: ~280 GB per recording (2 probes). 50 recordings = ~14 TB.
      Free space should be at least 14 TB (was 21 TB as of 2026-04-01).
- [ ] Preprocessed data dominates (128 GB/probe). Sorter choice barely
      affects disk — 2 vs 4 sorters saves only ~10 GB/probe.

### Phased sorter approach (optional)

If running a subset of sorters first (e.g., KS4 + SC2):

1. Comment out `SORT_MS5`, `SORT_TDC2`, and/or `SORT_LUPIN` in `main.nf`
   (both the process calls and their references in the `all_sorters` / `all_sorter_individual`
   channel mixes)
2. Submit the batch
3. Once complete, uncomment the remaining sorters and re-submit with `-resume`
   Everything from the first run caches; only new sorters + their downstream
   ANALYZE/CURATE/NWB_EXPORT will run.

## During the run

- [ ] Monitor with: `squeue -u $USER | wc -l` (should stay under 1024)
- [ ] Check trace file for failures: look for status != COMPLETED/CACHED
- [ ] Watch disk usage: `du -sh $RESULTS_PATH`
- [ ] Clean work dir periodically after confirmed successful steps:
      `nextflow clean -before <session_id>` (safe with publishDir mode 'link')

## After the run

- [ ] Verify all recordings completed: check trace file for expected job count
- [ ] Clean work directory: `nextflow clean` (results are hardlinked, not affected)
- [ ] Check quota: `lfs quota -h -p 3252387 /cfs/klemming`

## GPU bottleneck notes

gpugh has only 5-7 available nodes. 100 KS4 jobs (50 recordings x 2 probes)
will queue for a long time. KS4 will likely be the pipeline bottleneck.
Consider:
- Running KS4 last (phased approach: CPU sorters first, then KS4)
- Submitting during off-peak hours (weekends, nights)
- maxForks = 6 for KS4 to avoid flooding the GPU queue

## Notes

- NWB_EXPORT is **off by default** (`params.run_nwb_export = false`).
  Enable with `--run_nwb_export true` on the CLI if needed.
- Lupin uses a separate container (SI 0.104.0). COMPARE also uses this
  container since it needs to read lupin's sorting output.
- ANALYZE_LUPIN is a separate process from ANALYZE (different container).

## Reference

- SLURM account: naiss2026-3-127
- Partition walltimes: main 1d, shared 7d, gpugh 1d
- MaxSubmit: 1024 per user
- Quota: 29.3 TB on /cfs/klemming
- Pilot recording: 999770_day1_1_g0 (107 min, 2 probes)
  - ~280 GB results, ~1.3 TB work dir (includes failed re-runs)
  - Wall-clock: ~8h end-to-end (dominated by queue wait + KS4)
