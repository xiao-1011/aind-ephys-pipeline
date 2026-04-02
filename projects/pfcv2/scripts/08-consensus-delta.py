"""Step 8: Compare raw vs clean consensus to measure the effect of advanced curation.

Reads two consensus JSONs (produced by 06-compare.py) and generates comparison
plots + a summary text file.  Runs as a lightweight Nextflow process after
COMPARE and COMPARE_CLEAN.

Usage:
    python 08-consensus-delta.py <output_folder> \
        --raw consensus_labels.json \
        --clean consensus_clean.json
"""
from pathlib import Path
import argparse
import json

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np


# ── Helpers ──────────────────────────────────────────────────────────────────

def short_name(name: str) -> str:
    abbrevs = {
        "kilosort4": "KS4",
        "spykingcircus2": "SC2",
        "mountainsort5": "MS5",
        "tridesclous2": "TDC2",
        "lupin": "LPN",
    }
    return abbrevs.get(name, name)


def _load_consensus(path: Path) -> dict:
    with open(path) as f:
        return json.load(f)


def _sorter_stats(data: dict) -> list[dict]:
    """Extract per-sorter (n_total, n_consensus) from a consensus JSON."""
    sorters = data.get("sorters", [])
    stats = []
    for name in sorters:
        sorter_data = data.get(name, {})
        stats.append({
            "name": name,
            "short": short_name(name),
            "n_total": sorter_data.get("n_total", 0),
            "n_consensus": sorter_data.get("n_consensus", 0),
        })
    return stats


def _pairwise_matrix(data: dict) -> tuple[list[str], np.ndarray]:
    """Build pairwise agreement matrix from combinatorial subsets."""
    sorters = data.get("sorters", [])
    n = len(sorters)
    matrix = np.zeros((n, n), dtype=int)
    combinatorial = data.get("combinatorial", {})
    subsets = combinatorial.get("subsets", {})

    name_to_idx = {name: i for i, name in enumerate(sorters)}
    for key, info in subsets.items():
        names = info.get("sorters", [])
        if len(names) != 2:
            continue
        a, b = names
        if a in name_to_idx and b in name_to_idx:
            i, j = name_to_idx[a], name_to_idx[b]
            matrix[i, j] = info[a]["n_consensus"]
            matrix[j, i] = info[b]["n_consensus"]

    # Diagonal = total units
    for name in sorters:
        idx = name_to_idx[name]
        matrix[idx, idx] = data.get(name, {}).get("n_total", 0)

    return sorters, matrix


# ── Plots ────────────────────────────────────────────────────────────────────

def plot_paired_bars(raw_stats, clean_stats, plot_dir):
    """Plot A: Paired bar chart — per-sorter consensus raw vs clean."""
    names = [s["short"] for s in raw_stats]
    raw_vals = [s["n_consensus"] for s in raw_stats]

    # Match clean stats by sorter name (clean may have fewer sorters)
    clean_map = {s["name"]: s["n_consensus"] for s in clean_stats}
    clean_vals = [clean_map.get(s["name"], 0) for s in raw_stats]

    x = np.arange(len(names))
    width = 0.35

    fig, ax = plt.subplots(figsize=(max(8, len(names) * 2), 5))
    bars_raw = ax.bar(x - width / 2, raw_vals, width, label="Raw", color="#cccccc",
                       edgecolor="white")
    bars_clean = ax.bar(x + width / 2, clean_vals, width, label="Clean", color="#4c72b0",
                         edgecolor="white")

    # Delta annotations on clean bars
    for xi, (rv, cv) in enumerate(zip(raw_vals, clean_vals)):
        delta = cv - rv
        if rv > 0:
            pct = 100 * delta / rv
            label = f"+{delta} (+{pct:.0f}%)" if delta >= 0 else f"{delta} ({pct:.0f}%)"
        else:
            label = f"+{delta}" if delta >= 0 else str(delta)
        color = "#2a7f2a" if delta > 0 else "#cc3333" if delta < 0 else "#888888"
        ax.text(xi + width / 2, cv + max(max(raw_vals, default=1), max(clean_vals, default=1)) * 0.02,
                label, ha="center", va="bottom", fontsize=9, fontweight="bold", color=color)

    ax.set_xticks(x)
    ax.set_xticklabels(names, fontsize=11)
    ax.set_ylabel("Consensus units")
    ax.set_title("Consensus: Raw vs. Clean (after advanced curation)")
    ax.legend()
    ax.set_ylim(0, max(max(raw_vals, default=1), max(clean_vals, default=1)) * 1.2)
    fig.tight_layout()
    fig.savefig(plot_dir / "delta_paired_bars.png", dpi=150)
    plt.close(fig)


def plot_delta_heatmap(raw_data, clean_data, plot_dir):
    """Plot B: Pairwise agreement delta heatmap (green = improved)."""
    raw_names, raw_matrix = _pairwise_matrix(raw_data)
    clean_names, clean_matrix = _pairwise_matrix(clean_data)

    # Align matrices (clean may have fewer sorters)
    all_names = raw_names  # use raw as reference
    n = len(all_names)
    name_to_clean_idx = {name: i for i, name in enumerate(clean_names)}

    aligned_clean = np.zeros((n, n), dtype=int)
    for i, ni in enumerate(all_names):
        for j, nj in enumerate(all_names):
            ci = name_to_clean_idx.get(ni)
            cj = name_to_clean_idx.get(nj)
            if ci is not None and cj is not None:
                aligned_clean[i, j] = clean_matrix[ci, cj]

    delta = aligned_clean - raw_matrix
    # Zero out diagonal (total unit count delta is not meaningful here)
    np.fill_diagonal(delta, 0)

    short_names = [short_name(n) for n in all_names]
    vmax = max(abs(delta.min()), abs(delta.max()), 1)

    fig, ax = plt.subplots(figsize=(6, 5))
    im = ax.imshow(delta, cmap="RdYlGn", aspect="equal", vmin=-vmax, vmax=vmax)

    ax.set_xticks(range(n))
    ax.set_yticks(range(n))
    ax.set_xticklabels(short_names, fontsize=10)
    ax.set_yticklabels(short_names, fontsize=10)

    for i in range(n):
        for j in range(n):
            if i == j:
                continue
            val = delta[i, j]
            text = f"+{val}" if val > 0 else str(val)
            color = "white" if abs(val) > vmax * 0.7 else "black"
            ax.text(j, i, text, ha="center", va="center",
                    fontsize=11, fontweight="bold", color=color)

    ax.set_title("Pairwise agreement change\n(clean − raw, green = improved)")
    fig.colorbar(im, ax=ax, shrink=0.8, label="Δ units")
    fig.tight_layout()
    fig.savefig(plot_dir / "delta_pairwise_heatmap.png", dpi=150)
    plt.close(fig)


def plot_survival_overlay(raw_data, clean_data, plot_dir):
    """Plot C: Overlaid survival curves — raw (dashed) vs clean (solid)."""
    raw_sorters = raw_data.get("sorters", [])
    clean_sorters = clean_data.get("sorters", [])
    all_sorter_names = raw_sorters  # use raw as reference

    n_sorters = len(all_sorter_names)
    if n_sorters == 0:
        return

    thresholds = list(range(1, n_sorters + 1))
    markers = ["o", "s", "^", "D", "v", "P"]
    colors = plt.cm.tab10(np.linspace(0, 1, n_sorters))

    fig, ax = plt.subplots(figsize=(7, 5))

    for idx, name in enumerate(all_sorter_names):
        color = colors[idx]
        marker = markers[idx % len(markers)]
        sn = short_name(name)

        # Raw
        raw_sorter = raw_data.get(name, {})
        raw_consensus = raw_sorter.get("consensus", {})
        raw_total = raw_sorter.get("n_total", 0)
        if raw_total > 0:
            # Count units surviving at each threshold using consensus match counts
            # consensus dict has {uid: bool} — count matches from match_map isn't
            # directly available, so approximate: at threshold 1 all units survive,
            # at threshold 2 only consensus units survive
            raw_n_consensus = raw_sorter.get("n_consensus", 0)
            raw_fracs = [1.0, raw_n_consensus / raw_total] + [0.0] * (n_sorters - 2)
            ax.plot(thresholds[:len(raw_fracs)], raw_fracs[:len(thresholds)],
                    marker=marker, linestyle="--", alpha=0.5, color=color,
                    linewidth=1.5, markersize=6)

        # Clean
        if name in clean_sorters:
            clean_sorter = clean_data.get(name, {})
            clean_total = clean_sorter.get("n_total", 0)
            if clean_total > 0:
                clean_n_consensus = clean_sorter.get("n_consensus", 0)
                clean_fracs = [1.0, clean_n_consensus / clean_total] + [0.0] * (n_sorters - 2)
                ax.plot(thresholds[:len(clean_fracs)], clean_fracs[:len(thresholds)],
                        marker=marker, linestyle="-", color=color,
                        linewidth=2, markersize=8, label=f"{sn}")

    ax.set_xticks(thresholds)
    ax.set_xlabel("Min. agreeing sorters")
    ax.set_ylabel("Fraction of units surviving")
    ax.set_title("Consensus survival: Raw (dashed) vs Clean (solid)")
    ax.set_ylim(-0.05, 1.05)
    ax.legend()
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(plot_dir / "delta_survival_overlay.png", dpi=150)
    plt.close(fig)


def write_summary(raw_data, clean_data, plot_dir):
    """Write a plain-text summary of the delta."""
    lines = ["Consensus Delta Summary", "=" * 50, ""]
    lines.append(f"{'Sorter':<10} {'Raw':>8} {'Clean':>8} {'Delta':>8} {'Change':>10}")
    lines.append("-" * 50)

    raw_sorters = raw_data.get("sorters", [])
    total_raw = 0
    total_clean = 0

    for name in raw_sorters:
        raw_n = raw_data.get(name, {}).get("n_consensus", 0)
        raw_t = raw_data.get(name, {}).get("n_total", 0)
        clean_n = clean_data.get(name, {}).get("n_consensus", 0)
        clean_t = clean_data.get(name, {}).get("n_total", 0)

        delta = clean_n - raw_n
        pct = f"{100 * delta / raw_n:+.1f}%" if raw_n > 0 else "N/A"
        sign = "+" if delta >= 0 else ""
        lines.append(
            f"{short_name(name):<10} "
            f"{raw_n:>4}/{raw_t:<4} "
            f"{clean_n:>4}/{clean_t:<4} "
            f"{sign}{delta:>7} "
            f"{pct:>10}"
        )
        total_raw += raw_n
        total_clean += clean_n

    lines.append("-" * 50)
    total_delta = total_clean - total_raw
    sign = "+" if total_delta >= 0 else ""
    pct = f"{100 * total_delta / total_raw:+.1f}%" if total_raw > 0 else "N/A"
    lines.append(f"{'TOTAL':<10} {total_raw:>8} {total_clean:>8} {sign}{total_delta:>7} {pct:>10}")
    lines.append("")

    summary_text = "\n".join(lines)
    print(summary_text)

    summary_file = plot_dir / "summary.txt"
    summary_file.write_text(summary_text)
    return summary_file


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Step 9: Compare raw vs clean consensus (delta plots)",
        formatter_class=argparse.RawTextHelpFormatter,
    )
    parser.add_argument("output_folder", type=str,
                        help="Path to output folder")
    parser.add_argument("--raw", type=str, required=True,
                        help="Path to raw consensus JSON (consensus_labels.json)")
    parser.add_argument("--clean", type=str, required=True,
                        help="Path to clean consensus JSON (consensus_clean.json)")
    args = parser.parse_args()

    output_folder = Path(args.output_folder)
    raw_path = Path(args.raw) if Path(args.raw).is_absolute() else output_folder / args.raw
    clean_path = Path(args.clean) if Path(args.clean).is_absolute() else output_folder / args.clean

    raw_data = _load_consensus(raw_path)
    clean_data = _load_consensus(clean_path)

    plot_dir = output_folder / "consensus_delta"
    plot_dir.mkdir(exist_ok=True)

    print(f"Raw consensus:   {raw_path.name}")
    print(f"Clean consensus: {clean_path.name}")
    print(f"Output:          {plot_dir}/\n")

    raw_stats = _sorter_stats(raw_data)
    clean_stats = _sorter_stats(clean_data)

    plot_paired_bars(raw_stats, clean_stats, plot_dir)
    print("  delta_paired_bars.png")

    plot_delta_heatmap(raw_data, clean_data, plot_dir)
    print("  delta_pairwise_heatmap.png")

    plot_survival_overlay(raw_data, clean_data, plot_dir)
    print("  delta_survival_overlay.png")

    summary_file = write_summary(raw_data, clean_data, plot_dir)
    print(f"  {summary_file.name}")

    print(f"\nConsensus delta analysis complete.")


if __name__ == "__main__":
    main()
