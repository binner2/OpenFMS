#!/usr/bin/env python3
"""
OpenFMS Results Plotter — Grafik Uretici
==========================================

AMAC: Deney sonuclarini akademik yayin kalitesinde grafiklere donusturur.

KULLANIM:
    python3 scripts/07_plot_results.py results/experiment_matrix_<timestamp>/
    python3 scripts/07_plot_results.py results/scalability_*.csv
    python3 scripts/07_plot_results.py results/memory_leak_*.csv

CIKTI:
    results/plots/
      ├── scalability_log_log.png        (Grafik 1: O(N^2) kaniti)
      ├── throughput_vs_robots.png       (Grafik 2: Throughput)
      ├── memory_timeline.png            (Grafik 3: Bellek zaman serisi)
      ├── cycle_time_boxplot.png         (Grafik 4: Dagılım)
      ├── network_impact.png             (Grafik 5: Ag etkisi)
      └── summary_table.png             (Grafik 6: Ozet tablo)

NEDEN ONEMLI:
    analysis/06_DENEY_TASARIMI.md bolum 6.4'te tanimlanan
    10 grafik tipini uretir. Akademik yayin icin zorunlu.
"""

import os
import sys
import csv
import json
import math
from pathlib import Path
from datetime import datetime

# Matplotlib/numpy opsiyonel — yoksa metin rapor uret
try:
    import matplotlib
    matplotlib.use('Agg')  # Headless
    import matplotlib.pyplot as plt
    import matplotlib.ticker as ticker
    import numpy as np
    HAS_MATPLOTLIB = True
except ImportError:
    HAS_MATPLOTLIB = False
    print("[WARN] matplotlib bulunamadi. Yalnizca metin rapor uretilecek.")
    print("       Yuklemek icin: pip install matplotlib numpy")


def load_csv(filepath):
    """CSV dosyasini dict listesine yukler."""
    with open(filepath, 'r') as f:
        reader = csv.DictReader(f)
        return list(reader)


def load_experiment_matrix(matrix_dir):
    """Deney matris dizinini yukler."""
    csv_path = os.path.join(matrix_dir, 'results.csv')
    config_path = os.path.join(matrix_dir, 'matrix_config.json')

    data = load_csv(csv_path) if os.path.exists(csv_path) else []
    config = {}
    if os.path.exists(config_path):
        with open(config_path) as f:
            config = json.load(f)

    return data, config


def plot_scalability_log_log(data, output_dir):
    """Grafik 1: Dongu suresi vs robot sayisi (log-log)."""
    if not HAS_MATPLOTLIB:
        return

    robot_counts = []
    cycle_times = []

    for row in data:
        n = int(row.get('robot_count', 0))
        t = float(row.get('est_cycle_ms', 0) or row.get('avg_cycle_ms', 0))
        if n > 0 and t > 0:
            robot_counts.append(n)
            cycle_times.append(t)

    if not robot_counts:
        print("[WARN] scalability verisi bos, grafik uretilemiyor.")
        return

    fig, ax = plt.subplots(figsize=(8, 6))

    # Gercek veri
    ax.scatter(robot_counts, cycle_times, color='#2196F3', s=60, zorder=3, label='Olcum')

    # O(N^2) trend cizgisi
    n_range = np.linspace(min(robot_counts), max(robot_counts), 100)
    # Fit: T = a * N^2
    if len(set(robot_counts)) >= 2:
        # Basit log-log fit
        log_n = np.log(robot_counts)
        log_t = np.log(cycle_times)
        coeffs = np.polyfit(log_n, log_t, 1)
        slope = coeffs[0]
        intercept = coeffs[1]

        fit_t = np.exp(intercept) * n_range ** slope
        ax.plot(n_range, fit_t, '--', color='#F44336', linewidth=2,
                label=f'Trend: O(N^{slope:.1f})')

    # O(N) referans cizgisi
    if cycle_times:
        scale_factor = cycle_times[0] / robot_counts[0]
        linear_t = n_range * scale_factor
        ax.plot(n_range, linear_t, ':', color='#4CAF50', linewidth=1.5,
                label='Ideal: O(N)')

    # 2 saniye esik cizgisi
    ax.axhline(y=2000, color='#FF9800', linestyle='-', linewidth=1, alpha=0.7,
               label='Hedef: <2000ms')

    ax.set_xscale('log')
    ax.set_yscale('log')
    ax.set_xlabel('Robot Sayisi (N)', fontsize=12)
    ax.set_ylabel('Dongu Suresi (ms)', fontsize=12)
    ax.set_title('OpenFMS Olceklenebilirlik — Dongu Suresi vs Robot Sayisi', fontsize=13)
    ax.legend(fontsize=10)
    ax.grid(True, alpha=0.3)
    ax.xaxis.set_major_formatter(ticker.ScalarFormatter())
    ax.yaxis.set_major_formatter(ticker.ScalarFormatter())

    filepath = os.path.join(output_dir, 'scalability_log_log.png')
    fig.savefig(filepath, dpi=150, bbox_inches='tight')
    plt.close(fig)
    print(f"[OK] Grafik kaydedildi: {filepath}")


def plot_memory_timeline(data, output_dir):
    """Grafik 3: Bellek kullanimi zaman serisi."""
    if not HAS_MATPLOTLIB:
        return

    elapsed = []
    mem_mb = []

    for row in data:
        t = float(row.get('elapsed_sec', 0))
        m = float(row.get('manager_mem_mb', 0) or 0)
        if t > 0:
            elapsed.append(t / 60)  # Dakikaya cevir
            mem_mb.append(m)

    if not elapsed:
        print("[WARN] memory verisi bos.")
        return

    fig, ax = plt.subplots(figsize=(10, 5))

    ax.plot(elapsed, mem_mb, '-o', color='#9C27B0', markersize=3, linewidth=1.5,
            label='Manager Bellek')

    # Trend cizgisi
    if len(elapsed) >= 2:
        coeffs = np.polyfit(elapsed, mem_mb, 1)
        trend = np.poly1d(coeffs)
        ax.plot(elapsed, trend(elapsed), '--', color='#F44336', linewidth=2,
                label=f'Trend: {coeffs[0]:.2f} MB/dk')

    ax.set_xlabel('Zaman (dakika)', fontsize=12)
    ax.set_ylabel('Bellek (MB)', fontsize=12)
    ax.set_title('OpenFMS Fleet Manager — Bellek Kullanim Trendi', fontsize=13)
    ax.legend(fontsize=10)
    ax.grid(True, alpha=0.3)

    filepath = os.path.join(output_dir, 'memory_timeline.png')
    fig.savefig(filepath, dpi=150, bbox_inches='tight')
    plt.close(fig)
    print(f"[OK] Grafik kaydedildi: {filepath}")


def plot_experiment_summary(data, output_dir):
    """Grafik 6: Deney matrisi ozet tablosu."""
    if not HAS_MATPLOTLIB:
        return

    # Robot sayisina gore grupla
    from collections import defaultdict
    groups = defaultdict(list)
    for row in data:
        n = int(row.get('robot_count', 0))
        t = float(row.get('est_cycle_ms', 0) or 0)
        m = float(row.get('manager_mem_mb', '0').replace('MiB', '').strip() or 0)
        groups[n].append({'cycle': t, 'mem': m})

    if not groups:
        return

    robot_counts = sorted(groups.keys())
    means = [np.mean([g['cycle'] for g in groups[n]]) for n in robot_counts]
    stds = [np.std([g['cycle'] for g in groups[n]]) for n in robot_counts]

    fig, ax = plt.subplots(figsize=(8, 5))
    x = range(len(robot_counts))
    bars = ax.bar(x, means, yerr=stds, capsize=5, color='#2196F3', alpha=0.8,
                  edgecolor='#1565C0', linewidth=1.2)
    ax.axhline(y=2000, color='#F44336', linestyle='--', linewidth=1.5,
               label='Hedef: <2000ms')

    ax.set_xticks(x)
    ax.set_xticklabels([str(n) for n in robot_counts])
    ax.set_xlabel('Robot Sayisi', fontsize=12)
    ax.set_ylabel('Dongu Suresi (ms)', fontsize=12)
    ax.set_title('OpenFMS — Robot Sayisina Gore Dongu Suresi', fontsize=13)
    ax.legend(fontsize=10)
    ax.grid(True, alpha=0.3, axis='y')

    filepath = os.path.join(output_dir, 'summary_bar_chart.png')
    fig.savefig(filepath, dpi=150, bbox_inches='tight')
    plt.close(fig)
    print(f"[OK] Grafik kaydedildi: {filepath}")


def generate_text_report(data, output_dir, source_name):
    """Matplotlib olmadan metin rapor uretir."""
    report_path = os.path.join(output_dir, 'text_report.txt')

    with open(report_path, 'w') as f:
        f.write(f"OpenFMS Results Text Report\n")
        f.write(f"===========================\n")
        f.write(f"Kaynak: {source_name}\n")
        f.write(f"Tarih: {datetime.now().isoformat()}\n")
        f.write(f"Satir sayisi: {len(data)}\n\n")

        if data:
            f.write(f"Sutunlar: {', '.join(data[0].keys())}\n\n")
            f.write("Ilk 10 satir:\n")
            for i, row in enumerate(data[:10]):
                f.write(f"  {i+1}. {row}\n")

    print(f"[OK] Metin rapor: {report_path}")


def main():
    if len(sys.argv) < 2:
        print("Kullanim:")
        print("  python3 scripts/07_plot_results.py <veri_dizini_veya_csv>")
        print("")
        print("Ornekler:")
        print("  python3 scripts/07_plot_results.py results/experiment_matrix_2026-03-12/")
        print("  python3 scripts/07_plot_results.py results/scalability_2026-03-12.csv")
        print("  python3 scripts/07_plot_results.py results/memory_leak_2026-03-12.csv")
        sys.exit(1)

    source = sys.argv[1]
    output_dir = os.path.join('results', 'plots')
    os.makedirs(output_dir, exist_ok=True)

    print(f"[INFO] Kaynak: {source}")
    print(f"[INFO] Cikti: {output_dir}")

    # Kaynak tipini belirle
    if os.path.isdir(source):
        # Deney matrisi dizini
        data, config = load_experiment_matrix(source)
        print(f"[INFO] {len(data)} deney yuklendi")

        if data:
            plot_scalability_log_log(data, output_dir)
            plot_experiment_summary(data, output_dir)
            generate_text_report(data, output_dir, source)

    elif source.endswith('.csv'):
        data = load_csv(source)
        print(f"[INFO] {len(data)} satir yuklendi")

        if 'manager_mem_mb' in (data[0] if data else {}):
            if 'elapsed_sec' in data[0]:
                # Memory leak CSV
                plot_memory_timeline(data, output_dir)
            else:
                # Scalability CSV
                plot_scalability_log_log(data, output_dir)
                plot_experiment_summary(data, output_dir)

        generate_text_report(data, output_dir, source)
    else:
        print(f"[ERROR] Desteklenmeyen dosya tipi: {source}")
        sys.exit(1)

    print(f"\n[OK] Tum grafikler '{output_dir}' dizinine kaydedildi.")


if __name__ == '__main__':
    main()
