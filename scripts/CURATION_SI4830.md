# SpikeInterface 0.105.0 overflow backport

The curation backport applies exactly [upstream PR #4830](https://github.com/SpikeInterface/spikeinterface/pull/4830),
commit `2750986478b23a5a4dac721dc550358ebe098813`. It casts classifier metrics to
float32 **before** replacing infinity with NaN, so conversion overflow reaches
the model's trained imputer as a missing value.

The build uses the existing x86 pipeline-base 1.4.0 SIF as its filesystem base.
It verifies the installed 0.105.0 source checksum, applies the vendored patch,
verifies the resulting upstream source checksum, recompiles its bytecode, and
runs formatter/imputer regression tests. Package versions remain pinned to the
base image. `/opt/si4830/provenance.json` records package versions, source/patch
checksums, the base-image SHA-256, and our pipeline commit. The resulting SIF has
adjacent `.sha256` and `.provenance.json` files. Existing images are not overwritten.
The build uses `--ignore-fakeroot-command`: Arrhenius's host fakeroot executable
cannot run against this older base image's libraries. The file-only patch works
with Apptainer's root-mapped namespace instead.

## Build on Arrhenius

Commit and push the build inputs, then pull them on Arrhenius. From the repository
root (important because Slurm runs a spool copy of the shell script):

```bash
U=/nobackup/proj/disk/dmclab/personal/$USER
sbatch --output="$U/session_log/build-curation-si4830-%j.out" scripts/build_curation_si4830.sh
```

`SI4830_REPO` can explicitly select the repository. `SI4830_BASE_IMAGE` selects the
existing base image; the output SIF can be supplied as the first positional argument.
Default output: `$U/containers/aind-ephys-curation_1.4.0_si4830.sif`.

## Verify the problematic session

After a successful build, submit from the repository root:

```bash
W="$U/batch_runs/20261006_180017/work/cohort08/20260721/vr2320260721_g0"
sbatch --output="$U/session_log/verify-curation-si4830-%j.out" \
  scripts/verify_curation_si4830.sh \
  "$W/78/55f90992c790b8fde621dd0e9e0d2e" \
  "$W/99/908b8de173d544ffdab0301e0c414d/capsule/results/postprocessed_block0_imec0.ap_recording1_group0.zarr"
```

The verification freezes Hugging Face model snapshots for both images, reproduces
the stock image's error on group1, and runs both UnitRefine classifier stages in
the patched image. Group0 is the unaffected comparison: labels and probabilities
must be exactly identical between images. It then replays the retained capsule
code/parameters against a copied group1 analyzer and checks the complete curation
outputs. Diagnostic JSON lists metrics mapped to missing values and spike counts.
Source analyzers are mounted read-only and their full file hashes checked again.

Output: `$U/session_log/si4830_verify_JOBID/`, including `verification.json`, model
revision/file hashes, predictions, image provenance, `capsule.log`, and
`capsule/results/`. This is a standalone verification, not a batch-manifest update
or a completed QC/NWB/archive recovery. Frozen model snapshots are recorded at
verification time; equality checks use those same snapshots in both images. The
capsule also queries the Hub for model filenames, so its replay requires network
access; the verifier checks the model revision before and after replay. If only
the final replay fails, rerun that phase without overwriting the frozen inputs:

```bash
sbatch --output="$U/session_log/replay-curation-si4830-%j.out" \
  scripts/replay_curation_si4830.sh "$U/session_log/si4830_verify_JOBID"
```

## Enable for future Nextflow curation

After verification passes:

```bash
export CURATION_SIF="$U/containers/aind-ephys-curation_1.4.0_si4830.sif"
sha256sum --check "$CURATION_SIF.sha256"
sbatch --export=ALL pipeline/arrhenius_submit.sh /path/to/raw/session
```

The process-level image override is outside the shared settings map, allowing
other completed upstream tasks to remain eligible for resume. To use the official
image again, unset `CURATION_SIF`. Existing frozen batch snapshots need this config
change explicitly applied before they can use the override.
