# PFC Pipeline — Roadmap

## In pipeline (current)
- [x] Preprocessing (phase shift → CMR → bandpass → bad channel removal → motion correction)
- [x] Spike sorting: Kilosort4 (GPU)
- [x] Spike sorting: SpykingCircus2 (CPU, parallel with KS4)
- [x] Sorter comparison: consensus unit flags (KS4 ∩ SC2)
- [x] Sorting analysis: SortingAnalyzer with full quality metrics
- [x] Auto-curation: QM threshold filtering (ISI, presence ratio, amplitude cutoff)
- [x] NWB export: units table with spike times, quality metrics, consensus flag

---

## Next — curation enhancements
These require testing that HuggingFace model downloads work reliably on Dardel compute nodes,
and that the SortingAnalyzer loads correctly after cross-task staging.

- [ ] `remove_redundant_units` — pre-curation deduplication of split/duplicate units
- [ ] UnitRefine noise/neural classifier (`SpikeInterface/UnitRefine_noise_neural_classifier_lightweight`)
- [ ] UnitRefine SUA/MUA classifier (`SpikeInterface/UnitRefine_sua_mua_classifier_lightweight`)
      → adds SUA/MUA labels to NWB units table
- [ ] Bombcell — rule-based unit classifier
- [ ] Auto-merge suggestions — `compute_merge_unit_groups` (save to JSON for manual review, not auto-applied)

## Next — NWB enhancements
- [ ] Session/subject metadata — populate NWB from lab metadata files once available on server
- [ ] LFP export — write LFP band (downsampled) to NWB ecephys
- [ ] Manual curation → NWB update — script to re-export NWB after Phy manual curation session

## Next — pipeline infrastructure
- [ ] Figurl visualization — interactive drift maps and unit summaries (needs kachery setup)
- [ ] Work dir cleanup script — `cleanup.sh` to remove `work/` and old logs after validated run
- [ ] QC summary report — per-session HTML (unit counts, metric distributions, consensus fraction)
- [ ] Per-session SLURM parallelism — one job per session for maximum throughput

## Next — sorters and parameters
- [ ] Kilosort 2.5 (GPU) — add once KS4 vs SC2 benchmarking complete
- [ ] KS4 parameter tuning — based on ground truth comparison with manual curation batch
- [ ] SC2 parameter tuning — same

## Longer term
- [ ] Ground truth comparison tooling — automated agreement scoring vs. manual curation batch
- [ ] Other projects — copy this folder structure for project2, project3
- [ ] Shared params — extract common params (probe type, brain region) into a per-project config
