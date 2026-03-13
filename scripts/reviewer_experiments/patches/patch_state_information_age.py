#!/usr/bin/env python3
"""
state.py Information Age Metrik Yamasi
=======================================
Bu script, state.py'ye information age hesaplama fonksiyonunu ekler.
Hakem S2.4'un istegi: network latency ile information age farkinin
acikca ayirt edilmesi.

Tanim:
    Information Age  = t_decision - t_state_generated
    Network Latency  = t_received - t_state_generated
    Staleness        = t_decision - t_received (cache bekleme suresi)
    Information Age  = Network Latency + Staleness

Kullanim:
    python3 patch_state_information_age.py [--apply | --revert | --check]
"""

import os
import sys
import shutil

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.abspath(os.path.join(SCRIPT_DIR, '..', '..', '..'))
STATE_PATH = os.path.join(PROJECT_DIR, 'submodules', 'state.py')
BACKUP_PATH = STATE_PATH + '.backup_pre_info_age'

MARKER = '# === INFORMATION AGE METRIC (S2.4) ==='

INFO_AGE_CODE = '''
    # === INFORMATION AGE METRIC (S2.4) ===
    def compute_information_age(self):
        """Her robot icin bilgi yasini hesaplar.

        Information Age = Su an - cache'teki state mesajinin timestamp'i
        Bu, controller'in karar verirken kullandigi bilginin
        ne kadar eski oldugunu gosterir.

        Returns:
            dict: {robot_id: {"info_age_s": float, "network_latency_s": float,
                              "staleness_s": float, "state_timestamp": str}}
        """
        import time as _ia_time
        from datetime import datetime as _ia_datetime

        now = _ia_time.time()
        ages = {}

        for robot_id, cached_state in self.cache.items():
            msg_timestamp_str = cached_state.get("timestamp")
            receive_time = cached_state.get("_receive_time", now)

            if msg_timestamp_str:
                try:
                    msg_time = _ia_datetime.fromisoformat(msg_timestamp_str).timestamp()
                    info_age = now - msg_time  # t_decision - t_generated
                    network_latency = receive_time - msg_time  # t_received - t_generated
                    staleness = now - receive_time  # t_decision - t_received

                    ages[robot_id] = {
                        "info_age_s": round(info_age, 4),
                        "network_latency_s": round(max(0, network_latency), 4),
                        "staleness_s": round(max(0, staleness), 4),
                        "state_timestamp": msg_timestamp_str
                    }
                except (ValueError, TypeError):
                    ages[robot_id] = {
                        "info_age_s": -1,
                        "network_latency_s": -1,
                        "staleness_s": -1,
                        "state_timestamp": msg_timestamp_str
                    }

        return ages

    def compute_fleet_info_age_summary(self):
        """Filo genelinde information age ozet istatistikleri.

        Returns:
            dict: {"avg_info_age_s", "max_info_age_s", "avg_staleness_s",
                   "avg_network_latency_s", "robot_count", "stale_robots": [...]}
        """
        ages = self.compute_information_age()
        if not ages:
            return {"avg_info_age_s": 0, "max_info_age_s": 0,
                    "avg_staleness_s": 0, "avg_network_latency_s": 0,
                    "robot_count": 0, "stale_robots": []}

        valid_ages = {k: v for k, v in ages.items() if v["info_age_s"] >= 0}
        if not valid_ages:
            return {"avg_info_age_s": 0, "max_info_age_s": 0,
                    "avg_staleness_s": 0, "avg_network_latency_s": 0,
                    "robot_count": 0, "stale_robots": []}

        info_ages = [v["info_age_s"] for v in valid_ages.values()]
        staleness_vals = [v["staleness_s"] for v in valid_ages.values()]
        latency_vals = [v["network_latency_s"] for v in valid_ages.values()]

        # Bayat robot tespiti: info_age > 2 saniye
        stale_threshold = 2.0
        stale_robots = [k for k, v in valid_ages.items()
                       if v["info_age_s"] > stale_threshold]

        return {
            "avg_info_age_s": round(sum(info_ages) / len(info_ages), 4),
            "max_info_age_s": round(max(info_ages), 4),
            "avg_staleness_s": round(sum(staleness_vals) / len(staleness_vals), 4),
            "avg_network_latency_s": round(sum(latency_vals) / len(latency_vals), 4),
            "robot_count": len(valid_ages),
            "stale_robots": stale_robots
        }
    # === END INFORMATION AGE METRIC ===
'''


def check_patched():
    if not os.path.exists(STATE_PATH):
        print(f"HATA: {STATE_PATH} bulunamadi!")
        return None
    with open(STATE_PATH, 'r') as f:
        content = f.read()
    return MARKER in content


def apply_patch():
    status = check_patched()
    if status is None:
        return False
    if status:
        print("state.py zaten yamali. Islem yapilmadi.")
        return True

    shutil.copy2(STATE_PATH, BACKUP_PATH)
    print(f"Yedek: {BACKUP_PATH}")

    with open(STATE_PATH, 'r') as f:
        content = f.read()

    # compute_robot_avg_latency fonksiyonundan once ekle
    insertion_point = content.find('    def compute_robot_avg_latency')
    if insertion_point == -1:
        # Dosya sonuna ekle
        content += INFO_AGE_CODE
    else:
        content = content[:insertion_point] + INFO_AGE_CODE + '\n' + content[insertion_point:]

    with open(STATE_PATH, 'w') as f:
        f.write(content)

    print(f"Information age metrigi eklendi: {STATE_PATH}")
    return True


def revert_patch():
    if not os.path.exists(BACKUP_PATH):
        print("Yedek bulunamadi.")
        return False
    shutil.copy2(BACKUP_PATH, STATE_PATH)
    os.remove(BACKUP_PATH)
    print(f"Yama geri alindi: {STATE_PATH}")
    return True


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(__doc__)
        status = check_patched()
        if status is None:
            print("Durum: Dosya bulunamadi!")
        elif status:
            print("Durum: YAMALI")
        else:
            print("Durum: ORIJINAL")
        sys.exit(0)

    action = sys.argv[1]
    if action == '--apply':
        sys.exit(0 if apply_patch() else 1)
    elif action == '--revert':
        sys.exit(0 if revert_patch() else 1)
    elif action == '--check':
        status = check_patched()
        print("PATCHED" if status else "ORIGINAL")
        sys.exit(0)
    else:
        print(f"Bilinmeyen: {action}")
        sys.exit(1)
