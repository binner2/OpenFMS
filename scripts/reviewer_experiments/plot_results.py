#!/usr/bin/env python3
"""
Deney Sonuclari Gorsellestiricisi
==================================
Tum deney setleri (A-E) icin grafik ureticisi.
Hakem yanitinda kullanilacak akademik kalitede grafikler uretir.

Kullanim:
    python3 plot_results.py --set A          # Sadece Set A grafikleri
    python3 plot_results.py --set B          # Sadece Set B grafikleri
    python3 plot_results.py --all            # Tum setler
    python3 plot_results.py --set A --show   # Grafikleri goster (kaydetme)

Uretilen Grafikler:
    Set A: T_cycle vs N (log-log), Throughput vs N, CPU/RAM vs N
    Set B: Ablation karsilastirma bar chart
    Set C: Parametre hassasiyet grafikleri (OAT)
    Set D: Waitpoint doygunluk grafigi, secondary congestion
    Set E: Information age vs publish interval
"""

import argparse
import os
import sys
import csv
import json
from collections import defaultdict

try:
    import matplotlib
    matplotlib.use('Agg')  # Headless rendering
    import matplotlib.pyplot as plt
    import matplotlib.ticker as ticker
    import numpy as np
except ImportError:
    print("HATA: matplotlib ve numpy gerekli.")
    print("  pip install matplotlib numpy")
    sys.exit(1)

# Akademik stil ayarlari
plt.rcParams.update({
    'font.size': 11,
    'font.family': 'serif',
    'axes.labelsize': 12,
    'axes.titlesize': 13,
    'xtick.labelsize': 10,
    'ytick.labelsize': 10,
    'legend.fontsize': 10,
    'figure.figsize': (8, 5),
    'figure.dpi': 150,
    'savefig.dpi': 300,
    'savefig.bbox_inches': 'tight',
    'axes.grid': True,
    'grid.alpha': 0.3,
})

RESULTS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           '..', '..', 'results', 'reviewer_experiments')


def load_csv(filepath):
    """CSV dosyasini okur, header'i temizler."""
    if not os.path.exists(filepath):
        print(f"  Dosya bulunamadi: {filepath}")
        return []
    with open(filepath, 'r') as f:
        reader = csv.DictReader(f)
        # Strip whitespace from headers
        reader.fieldnames = [h.strip() for h in reader.fieldnames]
        return [row for row in reader]


def safe_float(val, default=0.0):
    try:
        return float(val)
    except (ValueError, TypeError):
        return default


def compute_stats(values):
    """mean, std, median, p95 hesapla."""
    if not values:
        return {'mean': 0, 'std': 0, 'median': 0, 'p95': 0, 'n': 0}
    arr = np.array(values)
    return {
        'mean': np.mean(arr),
        'std': np.std(arr),
        'median': np.median(arr),
        'p95': np.percentile(arr, 95) if len(arr) > 1 else arr[0],
        'n': len(arr)
    }


# ============================================================
# SET A: OLCEKLENDIRME GRAFIKLERI
# ============================================================
def plot_set_a(show=False):
    """Scaling experiment grafikleri."""
    csv_path = os.path.join(RESULTS_DIR, 'A_scaling', 'results.csv')
    plot_dir = os.path.join(RESULTS_DIR, 'A_scaling', 'plots')
    os.makedirs(plot_dir, exist_ok=True)

    data = load_csv(csv_path)
    if not data:
        print("Set A: Veri bulunamadi.")
        return

    # Robot sayisina gore gruplama
    by_n = defaultdict(list)
    for row in data:
        n = int(safe_float(row.get('robot_count', 0)))
        by_n[n].append(row)

    ns = sorted(by_n.keys())
    if not ns:
        return

    # --- Grafik 1: T_cycle vs N (log-log) ---
    fig, ax = plt.subplots()
    means = [compute_stats([safe_float(r.get('avg_cycle_ms', 0)) for r in by_n[n]])
             for n in ns]
    ax.errorbar(ns, [m['mean'] for m in means],
                yerr=[m['std'] for m in means],
                marker='o', capsize=4, linewidth=2, label='Measured $T_{cycle}$')

    # O(N^2) referans cizgisi
    if len(ns) >= 2 and means[0]['mean'] > 0:
        ref_n = ns[0]
        ref_val = means[0]['mean']
        theoretical = [ref_val * (n / ref_n) ** 2 for n in ns]
        ax.plot(ns, theoretical, '--', color='red', alpha=0.7,
                label='$O(N^2)$ theoretical', linewidth=1.5)

    ax.set_xscale('log', base=2)
    ax.set_yscale('log')
    ax.set_xlabel('Robot Count (N)')
    ax.set_ylabel('Decision Cycle Time $T_{cycle}$ (ms)')
    ax.set_title('Scalability: Decision Cycle Time vs Fleet Size')
    ax.legend()
    ax.xaxis.set_major_formatter(ticker.ScalarFormatter())
    plt.savefig(os.path.join(plot_dir, 'scalability_log_log.png'))
    print(f"  Kaydedildi: {plot_dir}/scalability_log_log.png")
    if show:
        plt.show()
    plt.close()

    # --- Grafik 2: Throughput vs N ---
    fig, ax = plt.subplots()
    tp_stats = [compute_stats([safe_float(r.get('throughput_per_min', 0)) for r in by_n[n]])
                for n in ns]
    ax.errorbar(ns, [s['mean'] for s in tp_stats],
                yerr=[s['std'] for s in tp_stats],
                marker='s', capsize=4, linewidth=2, color='green')
    # Linear ideal
    if tp_stats[0]['mean'] > 0:
        ideal = [tp_stats[0]['mean'] * n / ns[0] for n in ns]
        ax.plot(ns, ideal, '--', color='gray', alpha=0.5, label='Linear ideal')
    ax.set_xlabel('Robot Count (N)')
    ax.set_ylabel('Throughput (tasks/min)')
    ax.set_title('Throughput Scalability')
    ax.legend()
    plt.savefig(os.path.join(plot_dir, 'throughput_vs_N.png'))
    print(f"  Kaydedildi: {plot_dir}/throughput_vs_N.png")
    if show:
        plt.show()
    plt.close()

    # --- Grafik 3: CPU & RAM vs N ---
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(12, 5))
    cpu_stats = [compute_stats([safe_float(r.get('avg_cpu_pct', 0)) for r in by_n[n]])
                 for n in ns]
    mem_stats = [compute_stats([safe_float(r.get('peak_mem_mb', 0)) for r in by_n[n]])
                 for n in ns]

    ax1.errorbar(ns, [s['mean'] for s in cpu_stats],
                 yerr=[s['std'] for s in cpu_stats],
                 marker='o', capsize=4, color='orange')
    ax1.set_xlabel('Robot Count (N)')
    ax1.set_ylabel('CPU Usage (%)')
    ax1.set_title('Computational Overhead: CPU')

    ax2.errorbar(ns, [s['mean'] for s in mem_stats],
                 yerr=[s['std'] for s in mem_stats],
                 marker='o', capsize=4, color='purple')
    ax2.set_xlabel('Robot Count (N)')
    ax2.set_ylabel('Peak Memory (MB)')
    ax2.set_title('Computational Overhead: Memory')

    plt.tight_layout()
    plt.savefig(os.path.join(plot_dir, 'computational_overhead.png'))
    print(f"  Kaydedildi: {plot_dir}/computational_overhead.png")
    if show:
        plt.show()
    plt.close()

    # --- Grafik 4: Conflict count vs N ---
    fig, ax = plt.subplots()
    conf_stats = [compute_stats([safe_float(r.get('total_conflicts', 0)) for r in by_n[n]])
                  for n in ns]
    ax.errorbar(ns, [s['mean'] for s in conf_stats],
                yerr=[s['std'] for s in conf_stats],
                marker='^', capsize=4, color='red', linewidth=2)
    ax.set_xlabel('Robot Count (N)')
    ax.set_ylabel('Total Conflicts')
    ax.set_title('Traffic Conflicts vs Fleet Size')
    plt.savefig(os.path.join(plot_dir, 'conflicts_vs_N.png'))
    print(f"  Kaydedildi: {plot_dir}/conflicts_vs_N.png")
    if show:
        plt.show()
    plt.close()


# ============================================================
# SET B: ABLATION GRAFIKLERI
# ============================================================
def plot_set_b(show=False):
    """Ablation study bar chart."""
    csv_path = os.path.join(RESULTS_DIR, 'B_ablation', 'results.csv')
    plot_dir = os.path.join(RESULTS_DIR, 'B_ablation', 'plots')
    os.makedirs(plot_dir, exist_ok=True)

    data = load_csv(csv_path)
    if not data:
        print("Set B: Veri bulunamadi.")
        return

    # Config variant'a gore gruplama
    by_cfg = defaultdict(list)
    for row in data:
        cfg = row.get('config_variant', 'unknown')
        by_cfg[cfg].append(row)

    configs = ['baseline', 'no_fuzzy', 'no_priority', 'no_reroute', 'no_waitpoints']
    configs = [c for c in configs if c in by_cfg]
    if not configs:
        return

    # Metrikler
    metrics = ['avg_cycle_ms', 'throughput_per_min', 'total_conflicts', 'cumulative_delay_s']
    metric_labels = ['Cycle Time (ms)', 'Throughput\n(tasks/min)', 'Conflicts', 'Cumulative\nDelay (s)']

    fig, axes = plt.subplots(1, len(metrics), figsize=(4 * len(metrics), 5))
    if len(metrics) == 1:
        axes = [axes]

    colors = ['#2196F3', '#FF9800', '#4CAF50', '#F44336', '#9C27B0']
    x = np.arange(len(configs))
    width = 0.6

    for ax, metric, label in zip(axes, metrics, metric_labels):
        vals = []
        errs = []
        for cfg in configs:
            stats = compute_stats([safe_float(r.get(metric, 0)) for r in by_cfg[cfg]])
            vals.append(stats['mean'])
            errs.append(stats['std'])

        bars = ax.bar(x, vals, width, yerr=errs, capsize=4,
                      color=colors[:len(configs)], alpha=0.8)
        ax.set_xticks(x)
        ax.set_xticklabels([c.replace('_', '\n') for c in configs],
                           fontsize=8, rotation=45, ha='right')
        ax.set_ylabel(label)

        # Baseline referans cizgisi
        if vals and vals[0] > 0:
            ax.axhline(y=vals[0], color='blue', linestyle='--', alpha=0.3)

    fig.suptitle('Ablation Study: Component Contribution Analysis', fontsize=14)
    plt.tight_layout()
    plt.savefig(os.path.join(plot_dir, 'ablation_comparison.png'))
    print(f"  Kaydedildi: {plot_dir}/ablation_comparison.png")
    if show:
        plt.show()
    plt.close()

    # --- Yuzde degisim tablosu ---
    fig, ax = plt.subplots(figsize=(8, 4))
    ax.axis('off')

    baseline_vals = {}
    for metric in metrics:
        stats = compute_stats([safe_float(r.get(metric, 0)) for r in by_cfg.get('baseline', [])])
        baseline_vals[metric] = stats['mean']

    table_data = []
    for cfg in configs:
        row = [cfg]
        for metric in metrics:
            stats = compute_stats([safe_float(r.get(metric, 0)) for r in by_cfg[cfg]])
            if baseline_vals.get(metric, 0) > 0:
                pct = ((stats['mean'] - baseline_vals[metric]) / baseline_vals[metric]) * 100
                row.append(f"{pct:+.1f}%")
            else:
                row.append("N/A")
        table_data.append(row)

    table = ax.table(cellText=table_data,
                     colLabels=['Config'] + [m.replace('_', '\n') for m in metrics],
                     loc='center', cellLoc='center')
    table.auto_set_font_size(False)
    table.set_fontsize(9)
    table.scale(1.2, 1.5)
    ax.set_title('Ablation: Percentage Change from Baseline', fontsize=12, pad=20)
    plt.savefig(os.path.join(plot_dir, 'ablation_pct_table.png'))
    print(f"  Kaydedildi: {plot_dir}/ablation_pct_table.png")
    plt.close()


# ============================================================
# SET C: HASSASIYET GRAFIKLERI
# ============================================================
def plot_set_c(show=False):
    """Sensitivity analysis grafikleri."""
    csv_path = os.path.join(RESULTS_DIR, 'C_sensitivity', 'results.csv')
    plot_dir = os.path.join(RESULTS_DIR, 'C_sensitivity', 'plots')
    os.makedirs(plot_dir, exist_ok=True)

    data = load_csv(csv_path)
    if not data:
        print("Set C: Veri bulunamadi.")
        return

    # Parametre adina gore gruplama
    by_param = defaultdict(lambda: defaultdict(list))
    for row in data:
        pname = row.get('parameter_name', '')
        pval = safe_float(row.get('parameter_value', 0))
        by_param[pname][pval].append(row)

    target_metrics = ['avg_cycle_ms', 'throughput_per_min', 'total_conflicts']
    target_labels = ['Cycle Time (ms)', 'Throughput (tasks/min)', 'Conflicts']

    for pname, val_groups in by_param.items():
        fig, axes = plt.subplots(1, len(target_metrics), figsize=(5 * len(target_metrics), 4))
        if len(target_metrics) == 1:
            axes = [axes]

        vals_sorted = sorted(val_groups.keys())

        for ax, metric, label in zip(axes, target_metrics, target_labels):
            means = []
            stds = []
            for v in vals_sorted:
                stats = compute_stats([safe_float(r.get(metric, 0)) for r in val_groups[v]])
                means.append(stats['mean'])
                stds.append(stats['std'])

            ax.errorbar(vals_sorted, means, yerr=stds, marker='o', capsize=4, linewidth=2)
            ax.set_xlabel(pname.replace('_', ' ').title())
            ax.set_ylabel(label)

        fig.suptitle(f'Sensitivity: {pname.replace("_", " ").title()}', fontsize=13)
        plt.tight_layout()
        fname = f'sensitivity_{pname}.png'
        plt.savefig(os.path.join(plot_dir, fname))
        print(f"  Kaydedildi: {plot_dir}/{fname}")
        if show:
            plt.show()
        plt.close()


# ============================================================
# SET D: DOYGUNLUK GRAFIKLERI
# ============================================================
def plot_set_d(show=False):
    """Saturation grafikleri."""
    csv_path = os.path.join(RESULTS_DIR, 'D_saturation', 'results.csv')
    plot_dir = os.path.join(RESULTS_DIR, 'D_saturation', 'plots')
    os.makedirs(plot_dir, exist_ok=True)

    data = load_csv(csv_path)
    if not data:
        print("Set D: Veri bulunamadi.")
        return

    by_n = defaultdict(list)
    for row in data:
        n = int(safe_float(row.get('robot_count', 0)))
        by_n[n].append(row)

    ns = sorted(by_n.keys())
    if not ns:
        return

    wp_count = int(safe_float(data[0].get('waitpoint_count', 8)))

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(12, 5))

    # Grafik 1: Conflict count vs N (doygunluk noktasi isaretli)
    conf_stats = [compute_stats([safe_float(r.get('total_conflicts', 0)) for r in by_n[n]])
                  for n in ns]
    ax1.errorbar(ns, [s['mean'] for s in conf_stats],
                 yerr=[s['std'] for s in conf_stats],
                 marker='o', capsize=4, linewidth=2, color='red')
    ax1.axvline(x=wp_count, color='gray', linestyle='--', alpha=0.7,
                label=f'|$V_W$| = {wp_count}')
    ax1.fill_betweenx(ax1.get_ylim(), wp_count, max(ns) * 1.1,
                      alpha=0.1, color='red')
    ax1.set_xlabel('Robot Count (N)')
    ax1.set_ylabel('Total Conflicts')
    ax1.set_title('Conflicts in Saturation Zone')
    ax1.legend()

    # Grafik 2: Cycle time vs N (doygunluk)
    cycle_stats = [compute_stats([safe_float(r.get('avg_cycle_ms', 0)) for r in by_n[n]])
                   for n in ns]
    ax2.errorbar(ns, [s['mean'] for s in cycle_stats],
                 yerr=[s['std'] for s in cycle_stats],
                 marker='s', capsize=4, linewidth=2, color='orange')
    ax2.axvline(x=wp_count, color='gray', linestyle='--', alpha=0.7,
                label=f'|$V_W$| = {wp_count}')
    ax2.set_xlabel('Robot Count (N)')
    ax2.set_ylabel('Cycle Time (ms)')
    ax2.set_title('Decision Cycle in Saturation Zone')
    ax2.legend()

    plt.tight_layout()
    plt.savefig(os.path.join(plot_dir, 'saturation_analysis.png'))
    print(f"  Kaydedildi: {plot_dir}/saturation_analysis.png")
    if show:
        plt.show()
    plt.close()


# ============================================================
# SET E: INFORMATION AGE GRAFIKLERI
# ============================================================
def plot_set_e(show=False):
    """Information age grafikleri."""
    csv_path = os.path.join(RESULTS_DIR, 'E_information_age', 'results.csv')
    plot_dir = os.path.join(RESULTS_DIR, 'E_information_age', 'plots')
    os.makedirs(plot_dir, exist_ok=True)

    data = load_csv(csv_path)
    if not data:
        print("Set E: Veri bulunamadi.")
        return

    by_interval = defaultdict(list)
    for row in data:
        iv = safe_float(row.get('publish_interval_s', 0))
        by_interval[iv].append(row)

    intervals = sorted(by_interval.keys())
    if not intervals:
        return

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(12, 5))

    # Grafik 1: Information Age vs Publish Interval
    ia_stats = [compute_stats([safe_float(r.get('avg_info_age_ms', 0)) for r in by_interval[iv]])
                for iv in intervals]
    lat_stats = [compute_stats([safe_float(r.get('avg_network_latency_ms', 0)) for r in by_interval[iv]])
                 for iv in intervals]

    ax1.errorbar(intervals, [s['mean'] for s in ia_stats],
                 yerr=[s['std'] for s in ia_stats],
                 marker='o', capsize=4, linewidth=2, label='Information Age', color='blue')
    ax1.errorbar(intervals, [s['mean'] for s in lat_stats],
                 yerr=[s['std'] for s in lat_stats],
                 marker='s', capsize=4, linewidth=2, label='Network Latency', color='green')
    ax1.set_xlabel('State Publish Interval (s)')
    ax1.set_ylabel('Time (ms)')
    ax1.set_title('Information Age vs Network Latency')
    ax1.legend()

    # Grafik 2: Task quality / conflicts vs interval
    conf_stats = [compute_stats([safe_float(r.get('total_conflicts', 0)) for r in by_interval[iv]])
                  for iv in intervals]
    ax2.errorbar(intervals, [s['mean'] for s in conf_stats],
                 yerr=[s['std'] for s in conf_stats],
                 marker='^', capsize=4, linewidth=2, color='red')
    ax2.set_xlabel('State Publish Interval (s)')
    ax2.set_ylabel('Total Conflicts')
    ax2.set_title('Stale State Impact on Conflicts')

    plt.tight_layout()
    plt.savefig(os.path.join(plot_dir, 'information_age_analysis.png'))
    print(f"  Kaydedildi: {plot_dir}/information_age_analysis.png")
    if show:
        plt.show()
    plt.close()


# ============================================================
# MAIN
# ============================================================
def main():
    parser = argparse.ArgumentParser(description='Deney sonuclari gorsellestiricisi')
    parser.add_argument('--set', choices=['A', 'B', 'C', 'D', 'E'],
                        help='Grafik olusturulacak deney seti')
    parser.add_argument('--all', action='store_true', help='Tum setler')
    parser.add_argument('--show', action='store_true', help='Grafikleri goster')
    args = parser.parse_args()

    if not args.set and not args.all:
        parser.print_help()
        return

    plotters = {
        'A': ('Set A: Scaling', plot_set_a),
        'B': ('Set B: Ablation', plot_set_b),
        'C': ('Set C: Sensitivity', plot_set_c),
        'D': ('Set D: Saturation', plot_set_d),
        'E': ('Set E: Information Age', plot_set_e),
    }

    sets_to_plot = ['A', 'B', 'C', 'D', 'E'] if args.all else [args.set]

    for s in sets_to_plot:
        name, plotter = plotters[s]
        print(f"\n{'='*50}")
        print(f"  {name}")
        print(f"{'='*50}")
        plotter(show=args.show)

    print("\nTamamlandi.")


if __name__ == '__main__':
    main()
