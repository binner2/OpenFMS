#!/usr/bin/env python3
"""
FmMain.py Instrumentasyon Yamasi
================================
Bu script, FmMain.py'nin main_loop() fonksiyonuna dongu suresi
olcum instrumentasyonu ekler. Tum deneylerin temel veri kaynagi
olan cycle_times.csv dosyasini uretir.

Kullanim:
    python3 patch_fmmain_instrumentation.py [--apply | --revert | --check]

Uygulanan degisiklikler:
    1. main_loop() icine time.perf_counter() ile dongu suresi olcumu
    2. Her dongude cycle_times.csv'ye satir ekleme
    3. Conflict sayisi ve order sayisi kaydi
    4. psutil ile bellek kullanimi takibi (opsiyonel)

CSV Format:
    timestamp, cycle_id, robot_count, cycle_duration_ms,
    conflicts_this_cycle, orders_published, mem_rss_mb
"""

import os
import sys
import shutil
from datetime import datetime

# Proje kok dizini
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.abspath(os.path.join(SCRIPT_DIR, '..', '..', '..'))
FMMAIN_PATH = os.path.join(PROJECT_DIR, 'fleet_management', 'FmMain.py')
BACKUP_PATH = FMMAIN_PATH + '.backup_pre_instrumentation'

# Instrumentasyon kodu — main_loop() icine eklenecek
INSTRUMENTATION_IMPORTS = '''
# === INSTRUMENTATION IMPORTS (reviewer experiments) ===
import csv as _inst_csv
import os as _inst_os
_inst_cycle_id = 0
_inst_cycle_log_path = "logs/cycle_times.csv"
if not _inst_os.path.exists("logs"):
    _inst_os.makedirs("logs", exist_ok=True)
if not _inst_os.path.exists(_inst_cycle_log_path):
    with open(_inst_cycle_log_path, 'w') as _f:
        _inst_csv.writer(_f).writerow([
            "timestamp", "cycle_id", "robot_count", "cycle_duration_ms",
            "conflicts_this_cycle", "orders_published", "mem_rss_mb"
        ])
try:
    import psutil as _inst_psutil
    _inst_process = _inst_psutil.Process()
except ImportError:
    _inst_psutil = None
    _inst_process = None
# === END INSTRUMENTATION IMPORTS ===
'''

# Dongu oncesi olcum baslangici
CYCLE_START_MARKER = '# === INSTRUMENTATION: CYCLE START ==='
CYCLE_START_CODE = '''
                        # === INSTRUMENTATION: CYCLE START ===
                        import time as _inst_time
                        _inst_cycle_start = _inst_time.perf_counter()
                        _inst_cycle_id += 1
                        # === END CYCLE START ==='''

# Dongu sonrasi olcum ve kayit
CYCLE_END_MARKER = '# === INSTRUMENTATION: CYCLE END ==='
CYCLE_END_CODE = '''
                        # === INSTRUMENTATION: CYCLE END ===
                        _inst_cycle_end = _inst_time.perf_counter()
                        _inst_cycle_ms = (_inst_cycle_end - _inst_cycle_start) * 1000
                        _inst_conflicts = getattr(
                            self.schedule_handler.traffic_handler,
                            'collision_tracker', 0)
                        _inst_mem_mb = 0
                        if _inst_process:
                            try:
                                _inst_mem_mb = _inst_process.memory_info().rss / (1024 * 1024)
                            except Exception:
                                pass
                        try:
                            with open(_inst_cycle_log_path, 'a') as _f:
                                _inst_csv.writer(_f).writerow([
                                    _inst_time.time(),
                                    _inst_cycle_id,
                                    len(self.serial_numbers),
                                    f"{_inst_cycle_ms:.2f}",
                                    _inst_conflicts,
                                    0,  # orders_published placeholder
                                    f"{_inst_mem_mb:.1f}"
                                ])
                        except Exception:
                            pass
                        # === END CYCLE END ==='''


def check_instrumented():
    """FmMain.py'nin zaten instrumented olup olmadigini kontrol eder."""
    if not os.path.exists(FMMAIN_PATH):
        print(f"HATA: {FMMAIN_PATH} bulunamadi!")
        return None

    with open(FMMAIN_PATH, 'r') as f:
        content = f.read()

    if CYCLE_START_MARKER in content:
        return True
    return False


def apply_patch():
    """FmMain.py'ye instrumentasyon ekler."""
    status = check_instrumented()
    if status is None:
        return False
    if status:
        print("FmMain.py zaten instrumented. Islem yapilmadi.")
        return True

    # Yedek olustur
    shutil.copy2(FMMAIN_PATH, BACKUP_PATH)
    print(f"Yedek olusturuldu: {BACKUP_PATH}")

    with open(FMMAIN_PATH, 'r') as f:
        lines = f.readlines()

    new_lines = []
    imports_added = False
    in_main_loop = False
    cycle_start_added = False
    indent_level = ''

    for i, line in enumerate(lines):
        # Import blogu ekle (dosyanin basinda, mevcut importlardan sonra)
        if not imports_added and line.strip().startswith('class FmMain'):
            new_lines.append(INSTRUMENTATION_IMPORTS + '\n')
            imports_added = True

        # main_loop() icinde for dongusu oncesine CYCLE_START ekle
        if 'def main_loop(self)' in line:
            in_main_loop = True

        if in_main_loop and not cycle_start_added and \
           'for r_id in self.serial_numbers:' in line:
            new_lines.append(CYCLE_START_CODE + '\n')
            cycle_start_added = True
            new_lines.append(line)

            # for dongusunun bitisini bul ve CYCLE_END ekle
            # (terminal_graph_visualization satiri sonrasi)
            continue

        # traffic_handler visualization sonrasina CYCLE_END ekle
        if cycle_start_added and CYCLE_END_MARKER not in ''.join(new_lines) and \
           'terminal_graph_visualization()' in line:
            new_lines.append(line)
            new_lines.append(CYCLE_END_CODE + '\n')
            in_main_loop = False
            continue

        new_lines.append(line)

    with open(FMMAIN_PATH, 'w') as f:
        f.writelines(new_lines)

    print(f"Instrumentasyon basariyla uygulandi: {FMMAIN_PATH}")
    print(f"Cycle times CSV: logs/cycle_times.csv")
    return True


def revert_patch():
    """Instrumentasyonu geri alir."""
    if not os.path.exists(BACKUP_PATH):
        print("Yedek dosya bulunamadi. Manuel geri alma gerekli.")
        return False

    shutil.copy2(BACKUP_PATH, FMMAIN_PATH)
    os.remove(BACKUP_PATH)
    print(f"Instrumentasyon geri alindi: {FMMAIN_PATH}")
    return True


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(__doc__)
        print("\nMevcut durum:", end=" ")
        status = check_instrumented()
        if status is None:
            print("Dosya bulunamadi!")
        elif status:
            print("INSTRUMENTED")
        else:
            print("ORIJINAL (instrument edilmemis)")
        sys.exit(0)

    action = sys.argv[1]
    if action == '--apply':
        success = apply_patch()
        sys.exit(0 if success else 1)
    elif action == '--revert':
        success = revert_patch()
        sys.exit(0 if success else 1)
    elif action == '--check':
        status = check_instrumented()
        if status:
            print("INSTRUMENTED")
        elif status is False:
            print("ORIGINAL")
        sys.exit(0)
    else:
        print(f"Bilinmeyen aksiyon: {action}")
        print("Kullanim: --apply | --revert | --check")
        sys.exit(1)
