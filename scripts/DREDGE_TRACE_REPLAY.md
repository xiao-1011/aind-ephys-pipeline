# Five-session DREDGE-100 analyzer trace replay

This **downstream-only** paired test keeps each verified DREDGE-100 sort fixed.
For all five previously paired sessions (20 shanks), compare the original
filtered/referenced binary consumed by the corresponding KS4 pilot's pinned
postprocessing capsule against the
saved DREDGE-corrected trace from its verified archive. Both inputs are cast
to non-whitened float32 before postprocessing. This does not rerun sorting,
estimate new motion, or reproduce either sorter's internal whitening.

The archive provenance and matched pilot configurations were compared:
preprocessing, sorting and analyzer parameters agree except the DREDGE motion
compute/apply and KS4 built-in motion switches. The pinned capsule version
files agree exactly. Load the archived DREDGE analyzer, preserve its unit IDs,
spike times and channel sparsity in both arms, disable postprocessing duplicate
removal, and seed waveform/noise sampling identically. UnitRefine's local
model revisions and every cached file are checked against recorded hashes;
this cannot attest to current remote Hugging Face HEAD.

All output is under
`$U/baseline_pilots/dredge100_original_trace_20261009/`. Jobs mount source
pilots, previous model-verification snapshots, archives, raw recordings,
batch runs and the new staged DREDGE inputs read-only. Source archives and the
historical `skipped_failed` manifest record are never modified. Selective
archive staging verified each extracted member's SHA-256 against the verified
archive manifest (five sessions, ~197 GB). Stage jobs: `3569932` (5/5
complete). Probe jobs: `3569806` (5/5 complete).

Read-only preflight `3584535` failed before generating replay outputs: the
pilot's lazy preprocessing JSON contains a capsule-relative raw path and is
not loadable from its archived outputs directory. The waiting gate, remainder
array and report (`3584482`, `3584494`, `3584495`) were cancelled without
running. Revised sources use the materialized `binary_<shank>.json` actually
consumed by the pinned KS4 postprocessor (as in the completed KS4 trace test).

The frozen replay script `dredge_trace_replay.sh` first runs one shank as
`--array=0` (gate). The remaining `--array=1-19%4` shanks have an
`afterok:<gate>` dependency, so a gate failure blocks the rest. The report
has an `afterok:<remaining-array>` dependency, and independently checks all
20 completion markers. Revised frozen sources are in `source_v2/`, with a
separate checksum manifest; the original cancelled attempt and failed
preflight logs and sources are retained unchanged in `source/`. The
postprocessing code is copied and patched
to pass the historical channel mask, not symlinked; fixed sorting, float32
binary-JSON inputs and per-shank provenance remain in each replay directory.
The frozen SI #4830 image performs curation in each arm. All jobs verify source
checksums. Failures retain their partial directories; do not overwrite them.

Run `dredge_trace_report.sh` only after every replay's completion marker
passes. It writes a new `report_20261009/` directory: `comparison.csv`,
`waveform_stability_summary.json`, per-shank matched-unit transitions, labels
and QC metrics, and `REPORT.md`. Trust it only if `report_complete: passed`.
QC/SUA gains alone do not establish a preferable trace; inspect transitions,
motion jumps and edge-channel waveforms before changing any policy. This
pilot does not authorize a 35-session KS4 batch.
