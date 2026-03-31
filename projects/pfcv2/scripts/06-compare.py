"""Step 6: Compare sortings across all sorters to identify consensus units.

A unit is 'in consensus' if it is matched by at least --min-agreement sorters
in total (i.e. matched in at least --min-agreement - 1 other sorters).

All sorter_* subfolders in the output folder are discovered automatically.

Additionally computes combinatorial consensus for every subset of sorters
(all pairs, triples, ..., full set) and generates summary plots.

Saves:
  - consensus_labels.json  (flat + combinatorial consensus data)
  - consensus_plots/       (PNG visualizations)
"""
from pathlib import Path
from itertools import combinations
from collections import Counter
import argparse
import json

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

import spikeinterface.full as si


# ── Helpers ──────────────────────────────────────────────────────────────────

def short_name(name: str) -> str:
    """Abbreviate sorter names for plot labels."""
    abbrevs = {
        "kilosort4": "KS4",
        "spykingcircus2": "SC2",
        "mountainsort5": "MS5",
        "tridesclous2": "TDC2",
    }
    return abbrevs.get(name, name)


def compute_combinatorial_consensus(names, sortings, match_map):
    """For every subset of >=2 sorters, compute per-sorter consensus counts.

    A unit in sorter X is 'in consensus' for subset S if it was matched by
    ALL other sorters in S.

    Returns dict with 'subsets' and 'summary' keys.
    """
    subsets = {}
    summary = []

    for size in range(2, len(names) + 1):
        for combo in combinations(range(len(names)), size):
            subset_names = [names[i] for i in combo]
            subset_key = "+".join(subset_names)
            subset_result = {"sorters": subset_names}
            total_consensus = 0
            total_units = 0

            for idx in combo:
                name = names[idx]
                other_names = set(subset_names) - {name}
                n_consensus = 0
                n_total = len(match_map[name])
                for uid_str, matched in match_map[name].items():
                    if other_names.issubset(matched):
                        n_consensus += 1
                total_consensus += n_consensus
                total_units += n_total
                subset_result[name] = {
                    "n_total": n_total,
                    "n_consensus": n_consensus,
                    "pct": round(100 * n_consensus / n_total, 1) if n_total else 0,
                }

            mean_pct = round(
                np.mean([subset_result[n]["pct"] for n in subset_names]), 1
            )
            subsets[subset_key] = subset_result
            summary.append({
                "subset": subset_key,
                "size": size,
                "total_consensus_units": total_consensus,
                "mean_consensus_pct": mean_pct,
            })

    summary.sort(key=lambda x: (-x["size"], -x["mean_consensus_pct"]))
    return {"subsets": subsets, "summary": summary}


# ── Plotting ─────────────────────────────────────────────────────────────────

def plot_consensus_bars(combinatorial, names, plot_dir):
    """Plot A: Consensus unit counts per subset, grouped by subset size."""
    summary = combinatorial["summary"]
    subsets_data = combinatorial["subsets"]

    fig, ax = plt.subplots(figsize=(12, 5))
    colors = {2: "#4c72b0", 3: "#dd8452", 4: "#55a868"}
    size_labels = {2: "Pairs", 3: "Triples", 4: "All four"}

    labels = []
    values = []
    bar_colors = []
    for entry in sorted(summary, key=lambda x: (x["size"], -x["mean_consensus_pct"])):
        subset_key = entry["subset"]
        subset_names = subsets_data[subset_key]["sorters"]
        label = " + ".join(short_name(n) for n in subset_names)
        labels.append(label)
        values.append(entry["mean_consensus_pct"])
        bar_colors.append(colors.get(entry["size"], "#999999"))

    x = np.arange(len(labels))
    bars = ax.bar(x, values, color=bar_colors, edgecolor="white", linewidth=0.5)

    # Add value labels on bars
    for bar, val in zip(bars, values):
        ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 0.5,
                f"{val:.0f}%", ha="center", va="bottom", fontsize=8)

    ax.set_xticks(x)
    ax.set_xticklabels(labels, rotation=45, ha="right", fontsize=8)
    ax.set_ylabel("Mean consensus (%)")
    ax.set_title("Consensus units by sorter combination")
    ax.set_ylim(0, max(values) * 1.15 if values else 100)

    # Legend for subset sizes
    from matplotlib.patches import Patch
    legend_elements = [Patch(facecolor=colors[s], label=size_labels[s])
                       for s in sorted(colors) if s <= len(names)]
    ax.legend(handles=legend_elements, loc="upper right")

    fig.tight_layout()
    fig.savefig(plot_dir / "consensus_bars.png", dpi=150)
    plt.close(fig)


def plot_pairwise_heatmap(names, sortings, match_map, plot_dir):
    """Plot B: Pairwise agreement heatmap (sorter x sorter)."""
    n = len(names)
    matrix = np.zeros((n, n), dtype=int)

    # Diagonal = total units per sorter
    for i, name in enumerate(names):
        matrix[i, i] = len(match_map[name])

    # Off-diagonal = number of matched units (from sorter i's perspective)
    for i in range(n):
        for j in range(n):
            if i == j:
                continue
            count = sum(1 for matched in match_map[names[i]].values()
                        if names[j] in matched)
            matrix[i, j] = count

    short_names = [short_name(n) for n in names]

    fig, ax = plt.subplots(figsize=(6, 5))
    im = ax.imshow(matrix, cmap="YlOrRd", aspect="equal")

    ax.set_xticks(range(n))
    ax.set_yticks(range(n))
    ax.set_xticklabels(short_names, fontsize=10)
    ax.set_yticklabels(short_names, fontsize=10)

    # Annotate cells
    for i in range(n):
        for j in range(n):
            text_color = "white" if matrix[i, j] > matrix.max() * 0.7 else "black"
            ax.text(j, i, str(matrix[i, j]), ha="center", va="center",
                    fontsize=11, fontweight="bold", color=text_color)

    ax.set_title("Pairwise unit agreement\n(row sorter's units matched in column sorter)")
    fig.colorbar(im, ax=ax, shrink=0.8, label="# units")
    fig.tight_layout()
    fig.savefig(plot_dir / "pairwise_heatmap.png", dpi=150)
    plt.close(fig)


def plot_survival_curves(names, match_map, plot_dir):
    """Plot C: Per-sorter consensus survival curve.

    X = min number of agreeing sorters (1 = just itself, 2, 3, ... N)
    Y = fraction of that sorter's units surviving
    """
    n_sorters = len(names)
    thresholds = list(range(1, n_sorters + 1))

    fig, ax = plt.subplots(figsize=(7, 5))
    markers = ["o", "s", "^", "D", "v", "P"]

    for idx, name in enumerate(names):
        n_total = len(match_map[name])
        if n_total == 0:
            continue
        fractions = []
        for t in thresholds:
            # At threshold t, a unit survives if matched by >= t-1 other sorters
            n_surviving = sum(1 for matched in match_map[name].values()
                             if len(matched) >= t - 1)
            fractions.append(n_surviving / n_total)
        ax.plot(thresholds, fractions, marker=markers[idx % len(markers)],
                label=f"{short_name(name)} ({n_total} units)", linewidth=2, markersize=8)

    ax.set_xticks(thresholds)
    ax.set_xticklabels([str(t) for t in thresholds])
    ax.set_xlabel("Min. agreeing sorters")
    ax.set_ylabel("Fraction of units surviving")
    ax.set_title("Consensus survival curves")
    ax.set_ylim(-0.05, 1.05)
    ax.legend()
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(plot_dir / "survival_curves.png", dpi=150)
    plt.close(fig)


def plot_upset(names, match_map, plot_dir):
    """Plot D: UpSet-style intersection chart.

    For each unit in each sorter, compute its 'match signature' (the set of
    sorters it was found in: itself + all sorters that matched it).  Then count
    how many units share each signature.
    """
    sig_counter = Counter()
    for name in names:
        for uid_str, matched in match_map[name].items():
            sig = frozenset({name} | matched)
            sig_counter[sig] += 1

    if not sig_counter:
        return

    # Sort by count descending
    sorted_sigs = sig_counter.most_common()
    top_n = min(20, len(sorted_sigs))  # cap at 20 bars
    sorted_sigs = sorted_sigs[:top_n]

    fig, (ax_bars, ax_dots) = plt.subplots(
        2, 1, figsize=(max(8, top_n * 0.7), 6),
        gridspec_kw={"height_ratios": [3, 1]}, sharex=True,
    )

    labels = []
    counts = []
    for sig, count in sorted_sigs:
        label = " + ".join(sorted(short_name(n) for n in sig))
        labels.append(label)
        counts.append(count)

    x = np.arange(len(counts))
    ax_bars.bar(x, counts, color="#4c72b0", edgecolor="white")
    for xi, c in zip(x, counts):
        ax_bars.text(xi, c + max(counts) * 0.01, str(c),
                     ha="center", va="bottom", fontsize=8)
    ax_bars.set_ylabel("# units")
    ax_bars.set_title("Unit intersection patterns (which sorters found each unit)")

    # Dot matrix below
    all_short = [short_name(n) for n in names]
    for xi, (sig, _) in enumerate(sorted_sigs):
        sig_short = {short_name(n) for n in sig}
        for yi, sn in enumerate(all_short):
            if sn in sig_short:
                ax_dots.plot(xi, yi, "o", color="#333333", markersize=7)
            else:
                ax_dots.plot(xi, yi, "o", color="#dddddd", markersize=5)
        # Connect dots vertically for members
        members_y = [yi for yi, sn in enumerate(all_short) if sn in sig_short]
        if len(members_y) > 1:
            ax_dots.plot([xi, xi], [min(members_y), max(members_y)],
                         color="#333333", linewidth=1.5)

    ax_dots.set_yticks(range(len(all_short)))
    ax_dots.set_yticklabels(all_short)
    ax_dots.set_xticks(x)
    ax_dots.set_xticklabels([])
    ax_dots.set_xlim(-0.5, len(counts) - 0.5)
    ax_dots.invert_yaxis()

    fig.tight_layout()
    fig.savefig(plot_dir / "upset_intersections.png", dpi=150)
    plt.close(fig)


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description='Step 6: Multi-sorter consensus comparison',
        formatter_class=argparse.RawTextHelpFormatter,
    )
    parser.add_argument('output_folder', type=str,
                        help='Path to output folder (same as previous steps)')
    parser.add_argument(
        '--agreement-threshold', type=float, default=0.5,
        metavar='FLOAT',
        help='Min spike-overlap fraction to count as a matched unit (default: 0.5)',
    )
    parser.add_argument(
        '--min-agreement', type=int, default=2,
        metavar='INT',
        help=(
            'Minimum number of sorters that must detect a unit to be in consensus.\n'
            'E.g. 2 = found by any 2 sorters, 3 = found by any 3 sorters (default: 2)'
        ),
    )
    parser.add_argument(
        '--no-combinatorial', action='store_true',
        help='Skip combinatorial subset analysis and plots (only compute flat consensus)',
    )
    args = parser.parse_args()

    output_folder = Path(args.output_folder)

    sorter_folders = sorted(f for f in output_folder.glob('sorter_*') if f.is_dir())
    if len(sorter_folders) < 2:
        raise ValueError(
            f"Need at least 2 sorter_* folders for comparison, "
            f"found: {[f.name for f in sorter_folders]}"
        )

    print("Loading sortings...")
    sortings = []
    names = []
    for folder in sorter_folders:
        name = folder.name.replace('sorter_', '', 1)
        sorting = si.read_sorter_folder(folder)
        sortings.append(sorting)
        names.append(name)
        print(f"  {name}: {len(sorting.get_unit_ids())} units")

    # Per-unit match tracking: which other sorters matched each unit
    match_map = {
        name: {str(uid): set() for uid in sorting.get_unit_ids()}
        for name, sorting in zip(names, sortings)
    }

    # Pairwise comparisons — O(N^2/2) but N is small (2-6 sorters)
    for (i, name_i), (j, name_j) in combinations(enumerate(names), 2):
        print(f"\nComparing {name_i} vs {name_j}...")
        cmp = si.compare_two_sorters(
            sortings[i], sortings[j],
            sorting1_name=name_i,
            sorting2_name=name_j,
            match_score=args.agreement_threshold,
        )
        match_12 = cmp.hungarian_match_12
        match_21 = cmp.hungarian_match_21

        for uid in sortings[i].get_unit_ids():
            if int(match_12[uid]) != -1:
                match_map[name_i][str(uid)].add(name_j)

        for uid in sortings[j].get_unit_ids():
            if int(match_21[uid]) != -1:
                match_map[name_j][str(uid)].add(name_i)

    # ── Flat consensus (existing behavior) ───────────────────────────────
    other_sorter_threshold = args.min_agreement - 1

    print(f"\nConsensus threshold: detected by >= {args.min_agreement} of {len(names)} sorters")

    output = {
        'agreement_threshold': args.agreement_threshold,
        'min_agreement': args.min_agreement,
        'sorters': names,
    }

    for name, sorting in zip(names, sortings):
        consensus = {
            uid_str: (len(matched) >= other_sorter_threshold)
            for uid_str, matched in match_map[name].items()
        }
        n_consensus = sum(consensus.values())
        n_total = len(sorting.get_unit_ids())
        print(f"  {name}: {n_consensus}/{n_total} in consensus")
        output[name] = {
            'n_total':     n_total,
            'n_consensus': n_consensus,
            'consensus':   consensus,
        }

    # ── Combinatorial consensus ──────────────────────────────────────────
    if not args.no_combinatorial and len(names) >= 2:
        print("\n" + "=" * 60)
        print("Combinatorial consensus analysis")
        print("=" * 60)

        combinatorial = compute_combinatorial_consensus(names, sortings, match_map)
        output['combinatorial'] = combinatorial

        # Print summary table
        subsets_data = combinatorial["subsets"]
        current_size = 0
        size_labels = {2: "Pairs", 3: "Triples", 4: "All four", 5: "All five", 6: "All six"}
        for entry in combinatorial["summary"]:
            if entry["size"] != current_size:
                current_size = entry["size"]
                print(f"\n  {size_labels.get(current_size, f'{current_size}-way')}:")
            subset_key = entry["subset"]
            subset_names = subsets_data[subset_key]["sorters"]
            parts = []
            for sn in subset_names:
                d = subsets_data[subset_key][sn]
                parts.append(f"{short_name(sn)}:{d['n_consensus']}/{d['n_total']}({d['pct']}%)")
            label = " + ".join(short_name(n) for n in subset_names)
            print(f"    {label:40s}  mean={entry['mean_consensus_pct']}%  {' '.join(parts)}")

        # Generate plots
        plot_dir = output_folder / "consensus_plots"
        plot_dir.mkdir(exist_ok=True)

        print(f"\nGenerating plots -> {plot_dir}/")
        plot_consensus_bars(combinatorial, names, plot_dir)
        print("  consensus_bars.png")
        plot_pairwise_heatmap(names, sortings, match_map, plot_dir)
        print("  pairwise_heatmap.png")
        plot_survival_curves(names, match_map, plot_dir)
        print("  survival_curves.png")
        plot_upset(names, match_map, plot_dir)
        print("  upset_intersections.png")

    # ── Save JSON ────────────────────────────────────────────────────────
    output_file = output_folder / 'consensus_labels.json'
    with open(output_file, 'w') as f:
        json.dump(output, f, indent=2)
    print(f"\nConsensus labels saved to: {output_file}")


if __name__ == "__main__":
    main()
