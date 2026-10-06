# Sequential processing and session archives

Run on Arrhenius, from the pipeline clone:

```bash
bash scripts/start_arrhenius_batch.sh /path/to/verified-pilot-report.json
```

The launcher discovers session directories exactly three levels under
`raw_ecephys/`, validates AP data presence, freezes pipeline settings/scripts,
and submits an independent Slurm controller. Closing SSH or OpenCode does not
stop it. Sessions run sequentially, in cohort/date/session order.

Each session is processed, packed as **one uncompressed `.tar` file**, extracted
and verified, and only then cleaned. Tar is intentional: storage is acceptable,
and it avoids recompressing Zarr while reducing inode use. Archives are in
`session_archives/<cohort>/<date>/<session>.tar`. They contain corrected binaries,
sortings, analyzers, motion, QC, visualization, NWB-Zarr, configuration, and logs.
Operational recording paths are rewritten to relative paths; raw data are not
included or deleted. Historical provenance can still mention original paths.

Verification checks every archived file's SHA-256 and size, loads the extracted
recordings/analyzers without any live work/raw dependency, checks trace samples,
sortings, curated labels, motion, and NWB unit counts. The `.partial` archive is
renamed only after passing. A failed pipeline/archive stops the batch and retains
the failing session. There is no automatic deletion of old experiments.

**Cleanup is restricted to this batch's own `outputs/` and `work/` trees.**
The supplied verified pilot archive is adopted after checksum/parameter checks;
its pre-existing sources are preserved. Other existing archives require explicit
verification before adoption (the launcher refuses silent overwriting).

## Monitoring tomorrow

```bash
U=/nobackup/proj/disk/dmclab/personal/$USER
cat "$U/batch_runs/latest.json"
# Use the batch path reported above:
cat /path/to/batch/summary.tsv
tail -30 /path/to/batch/logs/batch-JOBID.out
squeue -u "$USER"
```

`summary.tsv` contains status, units, default-QC-passing units, UnitRefine SUA,
and SUA also passing QC. `manifest.json` and `progress.jsonl` record detailed
status and checksums. These small tracking files are intentionally retained.

## Restarting the same batch

After resolving the failure and confirming no batch controller is active:

```bash
sbatch --output=/path/to/batch/logs/batch-%j.out \
  /path/to/batch/snapshot/scripts/arrhenius_batch_controller.sh /path/to/batch
```

Completed archives are skipped. Incomplete Nextflow work within the same batch
can be resumed. Partial archives are deliberately retained and block a blind
retry: inspect/move them first. A three-day controller walltime may require a
restart for very large datasets; there is no promise all sessions finish overnight.

## Extracting and loading

```bash
tar -xf session.tar
```

Follow the included `RESTORE.md`. Use the archived pipeline-base image version
(currently 1.4.0 / SpikeInterface 0.105) to load the archived objects. Cleanup
removes the batch's Nextflow cache, so completed sessions cannot be resumed from
those intermediates; new analyses use the portable archived recordings instead.
