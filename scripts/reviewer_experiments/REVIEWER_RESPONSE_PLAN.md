# Hakem Yanıt Planı — Kod Değişiklikleri, Deneyler ve KPI Tanımları

**Makale:** OpenFMS: A VDA5050-Compliant Open-Source Benchmarking Baseline for Centralized AMR Fleet Management
**Tarih:** 2026-03-13
**Kapsam:** 7 hakem yorumunun her biri için gereken kod değişiklikleri, deney tasarımları ve metrik tanımları

---

## 1. GENEL STRATEJİ

Hakem yorumları iki ana kategoride:

| Kategori | Yorumlar | Gereken |
|----------|---------|---------|
| **Yeni deneyler** | M1.1, S2.1, M1.2, S2.2, S2.3 | Kod instrumentasyonu + deney script'leri |
| **Metin düzenleme** | M1.3, M1.4, S2.4 | Metrik netleştirme + yeni hesaplama |

---

## 2. KOD DEĞİŞİKLİKLERİ — DOSYA BAZINDA

### 2.1 `FmMain.py` — Döngü Süresi Instrumentasyonu (TÜM DENEYLER İÇİN ZORUNLU)

**Neden:** Hiçbir deney, döngü süresini ölçmeden anlamlı sonuç üretemez. Mevcut kodda `manage_robot()` çağrı süresi ölçülmüyor.

**Değişiklik:**
```python
# main_loop() içinde, robot döngüsü öncesi/sonrası:
import time, csv, os

cycle_log_path = "logs/cycle_times.csv"
if not os.path.exists(cycle_log_path):
    with open(cycle_log_path, 'w') as f:
        csv.writer(f).writerow([
            "timestamp", "cycle_id", "robot_count", "cycle_duration_ms",
            "conflicts_this_cycle", "orders_published", "mem_rss_mb"
        ])

cycle_start = time.perf_counter()
# ... mevcut robot döngüsü ...
cycle_end = time.perf_counter()
cycle_ms = (cycle_end - cycle_start) * 1000

with open(cycle_log_path, 'a') as f:
    csv.writer(f).writerow([
        time.time(), cycle_id, len(self.serial_numbers), cycle_ms,
        conflicts_this_cycle, orders_published, mem_rss_mb
    ])
```

**Etki:** Tüm deneyler bu CSV'yi okuyarak döngü süresi metriklerini üretir.

---

### 2.2 `FmScheduleHandler.py` — Genişletilmiş Analytics (M1.1, M1.2)

**Neden:** Mevcut `fm_analytics()` yalnızca metin çıktısı üretiyor. Deneyler için yapılandırılmış JSON/CSV çıktısı gerekli.

**Yeni fonksiyon:**
```python
def export_experiment_metrics(self, experiment_id, output_dir="results"):
    """Tüm metrikleri JSON olarak dışa aktarır — deney sonucu kaydı için."""
    metrics = {
        "experiment_id": experiment_id,
        "timestamp": datetime.now().isoformat(),
        "robot_count": len(self.serial_numbers),
        # Throughput
        "throughput": self._compute_throughput_summary(),
        # Task completion
        "task_completion": self._compute_task_completion_summary(),
        # Latency
        "latency": self._compute_latency_summary(),
        # Idle time
        "idle_time": self._compute_idle_summary(),
        # Conflicts
        "conflicts": {
            "total": self.traffic_handler.collision_tracker,
            "active": len(self.traffic_handler.robots_in_collision)
        },
        # Resource usage
        "resource": self._compute_resource_usage()
    }
    filepath = f"{output_dir}/metrics_{experiment_id}.json"
    with open(filepath, 'w') as f:
        json.dump(metrics, f, indent=2)
    return metrics
```

---

### 2.3 `state.py` — Information Age Metriği (S2.4)

**Neden:** Hakem S2.4, "network latency" ile "information age" farkını netleştirmemizi istiyor. Mevcut `record_msg_latency()` yalnızca iletim gecikmesini ölçüyor, bilginin yaşını (staleness) ölçmüyor.

**Tanım:**
```
Information Age = t_decision - t_robot_state_generated
Network Latency = t_received - t_robot_state_generated
Staleness = t_decision - t_received (bilginin cache'te bekleme süresi)

Information Age = Network Latency + Staleness
```

**Yeni fonksiyon:**
```python
def compute_information_age(self):
    """Her robot için bilgi yaşını hesaplar.

    Information Age = Şu an - cache'teki state mesajının timestamp'i
    Bu, controller'ın karar verirken kullandığı bilginin
    ne kadar eski olduğunu gösterir.
    """
    now = time.time()
    ages = {}
    for robot_id, cached_state in self.cache.items():
        msg_timestamp = cached_state.get("timestamp")
        if msg_timestamp:
            msg_time = datetime.fromisoformat(msg_timestamp).timestamp()
            ages[robot_id] = now - msg_time  # saniye
    return ages
```

---

### 2.4 `FmTaskHandler.py` — Ablation Toggle'ları (M1.2)

**Neden:** Ablation study, her bileşenin bireysel etkisini ölçmek için bileşenlerin devre dışı bırakılmasını gerektirir.

**Değişiklikler:**
```python
class FmTaskHandler:
    def __init__(self, ..., ablation_config=None):
        self.ablation = ablation_config or {}
        # Ablation seçenekleri:
        # "disable_fuzzy": True → FIFO atama kullan
        # "disable_priority": True → Tüm görevler eşit öncelik
        # "disable_reroute": True → Reroute mekanizmasını devre dışı bırak
        # "disable_waitpoints": True → Waitpoint'e yönlendirme yok

    def evaluate_robot_for_task(self, ...):
        if self.ablation.get("disable_fuzzy"):
            return 1.0  # Tüm robotlar eşit fitness → FIFO atama
        # ... mevcut fuzzy logic ...
```

---

### 2.5 `FmTrafficHandler.py` — Waitpoint Doygunluk Tespiti (S2.3)

**Neden:** Hakem S2.3, waitpoint kapasitesi aşıldığında ne olacağını soruyor.

**Yeni metrik:**
```python
def compute_waitpoint_saturation(self):
    """Waitpoint doygunluk oranını hesaplar.

    Saturation = occupied_waitpoints / total_waitpoints
    Eğer saturation = 1.0 → tüm waitpoint'ler dolu, secondary congestion riski
    """
    total_wp = len([item for item in self.task_dictionary.get('itinerary', [])
                    if item['description'] == 'waitpoint'])
    occupied_wp = sum(1 for node_id in self.traffic_control_set
                     if node_id.startswith('W'))
    return {
        "total_waitpoints": total_wp,
        "occupied_waitpoints": occupied_wp,
        "saturation_ratio": occupied_wp / max(total_wp, 1),
        "available": total_wp - occupied_wp
    }
```

---

## 3. PERFORMANS METRİKLERİ VE KPI TANIMLARI

### 3.1 Birincil KPI'lar (Tüm Deneylerde Kaydedilecek)

| KPI | Tanım | Birim | Hesaplama | Kaynak Dosya |
|-----|--------|-------|-----------|-------------|
| **T_cycle** | Karar döngüsü süresi | ms | `time.perf_counter()` farkı | `FmMain.py` |
| **Throughput** | Dakika başına tamamlanan görev | görev/dk | `completed_tasks / elapsed_minutes` | `order.py` |
| **Task Completion Rate** | Başarıyla tamamlanan görev oranı | % | `completed / (completed + failed + timeout) × 100` | `order.py` |
| **Cumulative Delay** | Kümülatif bekleme süresi | s | `Σ(wait_end - wait_start)` tüm robotlar | `order.py` |
| **Task Completion Time** | Görev tamamlanma süresi | s | `completion_timestamp - issuance_timestamp` | `order.py` |
| **Idle Time** | Robot boşta kalma süresi | s | `Σ(time_at_home_dock)` | `FmScheduleHandler.py` |
| **Conflict Count** | Toplam trafik çakışması | sayı | `collision_tracker` | `FmTrafficHandler.py` |

### 3.2 İkincil KPI'lar (Hakem Yanıtı İçin Ek)

| KPI | Tanım | Birim | Hangi Hakem | Hesaplama |
|-----|--------|-------|-------------|-----------|
| **Information Age** | Karar anında bilgi yaşı | s | S2.4 | `t_decision - t_state_generated` |
| **Waitpoint Saturation** | Waitpoint doygunluk oranı | [0,1] | S2.3 | `occupied_wp / total_wp` |
| **Reroute Count** | Yeniden rotalama sayısı | sayı | S2.3 | `reroute_robot()` çağrı sayısı |
| **Deadlock Duration** | İki+ robot karşılıklı bekleme | s | S2.1 | `2+ robot aynı anda "red" + waitpoint dolu` |
| **Computational Overhead** | CPU + bellek kullanımı | %, MB | M1.1 | `psutil.Process()` |
| **P_stale (Staleness Penalty)** | Bilgi bayatlığı cezası | s | S2.4 | `Eq. 23` (makaledeki formül) |
| **Secondary Congestion** | Waitpoint dolu iken yeni conflict | sayı | S2.3 | `waitpoint_saturation == 1.0 && new_conflict` |

### 3.3 Ablation KPI'ları (M1.2 İçin)

| Bileşen | Devre Dışı Bırakılınca | Ölçülecek Fark |
|---------|----------------------|----------------|
| **Fuzzy Logic** → FIFO | Görev atama kalitesi düşer | Throughput, idle time, task completion time |
| **Priority-based conflict** → FCFS | Yüksek öncelikli görevler gecikmeli | Cumulative delay, conflict count |
| **Waitpoint rerouting** → Halt-only | Robot yerinde bekler | Deadlock süresi, throughput |
| **Node reservation** → Free-for-all | Çarpışma artar | Conflict count (patlama beklenir) |

---

## 4. DENEY PLANI — HAKEM YORUMU BAZINDA

### 4.1 Deney Seti A: Ölçeklendirme (M1.1 + S2.1)

**Amaç:** 8 robot → 16, 24, 32, 48 robot simülasyonları

| Parametre | Değerler |
|-----------|---------|
| Robot sayısı (N) | 2, 4, 8, 16, 24, 32, 48 |
| Harita düğüm sayısı | Sabit oran: 3N checkpoint + N/2 waitpoint |
| Görev tipi | %70 transport, %20 charge, %10 move |
| Süre | 15 dakika (5dk warmup + 10dk ölçüm) |
| Tekrar | 5 (farklı random seed) |
| **Toplam deney:** | **7 × 5 = 35** |

**Kaydedilecek KPI'lar:** T_cycle, Throughput, Task Completion Rate, Cumulative Delay, Conflict Count, Computational Overhead (CPU, RAM)

**Beklenen çıktılar:**
- Tablo: Table I genişletilmiş versiyonu (N=2..48)
- Grafik 1: T_cycle vs N (log-log, O(N²) kanıtı)
- Grafik 2: Throughput vs N (doğrusallıktan sapma)
- Grafik 3: Computational overhead vs N

### 4.2 Deney Seti B: Ablation Study (M1.2)

**Amaç:** Her bileşenin bireysel katkısını ölçmek

| Konfigürasyon | Fuzzy | Priority | Reroute | Waitpoints |
|---------------|-------|----------|---------|------------|
| **Baseline (Full)** | ✅ | ✅ | ✅ | ✅ |
| **A1: No Fuzzy** | ❌ (FIFO) | ✅ | ✅ | ✅ |
| **A2: No Priority** | ✅ | ❌ (FCFS) | ✅ | ✅ |
| **A3: No Reroute** | ✅ | ✅ | ❌ | ✅ |
| **A4: No Waitpoints** | ✅ | ✅ | ✅ | ❌ (halt) |

| Parametre | Değer |
|-----------|-------|
| Robot sayısı | 8 (mevcut Table I ile uyumlu) |
| Süre | 15 dakika |
| Tekrar | 5 |
| **Toplam deney:** | **5 × 5 = 25** |

**Beklenen çıktılar:**
- Tablo: Ablation karşılaştırma tablosu
- Grafik: Bar chart — her bileşenin etkisi (% değişim)

### 4.3 Deney Seti C: Sensitivity Analysis (M1.2 ek)

**Amaç:** Fuzzy logic parametrelerinin (idle_time, battery, travel_time) eşik değerlerinin sistem performansına etkisi

| Parametre | Varsayılan | Test Değerleri |
|-----------|-----------|---------------|
| `idle_time` max | 300s | 100, 200, 300, 500 |
| `battery` low threshold | 40% | 20, 30, 40, 50 |
| `travel_time` short/long boundary | 200s | 100, 200, 300, 400 |
| `wait_time_default` | 10.5s | 5, 10.5, 20, 30 |

| Parametre | Değer |
|-----------|-------|
| Robot sayısı | 8 |
| Tek parametre değiştir (one-at-a-time) | 4 parametre × 4 değer |
| Tekrar | 3 |
| **Toplam deney:** | **16 × 3 = 48** |

### 4.4 Deney Seti D: Hold-and-Wait Saturation (S2.3)

**Amaç:** Waitpoint kapasitesinin aşıldığı noktayı deneysel olarak göstermek

| Parametre | Değerler |
|-----------|---------|
| Robot sayısı (N) | 4, 8, 12, 16, 20, 24 |
| Waitpoint sayısı (W) | Sabit: 8 (kasıtlı olarak düşük tutulur) |
| Harita: Dar koridor | Tek hat (linear chain), çapraz yol yok |
| **Toplam deney:** | **6 × 3 = 18** |

**Kaydedilecek ek KPI'lar:** Waitpoint saturation ratio, secondary congestion events, deadlock duration

### 4.5 Deney Seti E: Information Age (S2.4)

**Amaç:** Network latency vs information age ayrımını deneysel olarak göstermek

| Parametre | Değerler |
|-----------|---------|
| State publish interval | 0.1s, 0.5s, 1s, 2s, 5s |
| Robot sayısı | 8 |
| Tekrar | 3 |
| **Toplam deney:** | **5 × 3 = 15** |

**Kaydedilecek KPI'lar:** Network latency (mevcut), Information age (yeni), Task completion quality

---

## 5. SONUÇLARIN KAYDEDİLME FORMATI

### 5.1 Dosya Yapısı

```
results/
├── reviewer_experiments/
│   ├── A_scaling/
│   │   ├── config.json           # Deney matrisi konfigürasyonu
│   │   ├── results.csv           # Tüm sonuçlar (tek CSV)
│   │   ├── run_001/              # Her deney çalıştırması
│   │   │   ├── cycle_times.csv   # Döngü süreleri (zaman serisi)
│   │   │   ├── metrics.json      # Toplu metrikler
│   │   │   └── system_stats.csv  # CPU, RAM zaman serisi
│   │   └── plots/
│   │       ├── table1_extended.csv
│   │       ├── scalability_log_log.png
│   │       └── throughput_vs_N.png
│   ├── B_ablation/
│   ├── C_sensitivity/
│   ├── D_saturation/
│   └── E_information_age/
```

### 5.2 CSV Format (results.csv)

```csv
experiment_id,set,robot_count,config_variant,repeat,seed,duration_min,
avg_cycle_ms,p50_cycle_ms,p95_cycle_ms,p99_cycle_ms,max_cycle_ms,
throughput_per_min,task_completion_rate,total_tasks_completed,total_tasks_failed,
cumulative_delay_s,avg_task_completion_s,median_task_completion_s,
total_conflicts,total_reroutes,total_deadlocks,
avg_idle_time_s,fleet_utilization_pct,
avg_info_age_s,max_info_age_s,
waitpoint_saturation_avg,waitpoint_saturation_max,
secondary_congestion_events,
avg_cpu_pct,peak_mem_mb,
avg_latency_ms,p95_latency_ms
```

### 5.3 Her Deney İçin Kaydedilecek Ham Veriler

1. **cycle_times.csv** — Her döngünün süresi (ms), robot sayısı, conflict sayısı
2. **system_stats.csv** — 10sn aralıklarla CPU, RAM, MQTT mesaj sayısı
3. **metrics.json** — Toplu KPI'lar (deney sonunda hesaplanır)
4. **events.log** — Conflict, reroute, deadlock olaylarının zaman damgalı kaydı

---

## 6. TOPLAM DENEY MATRİSİ

| Set | Hakem | Deney Sayısı | Tahmini Süre |
|-----|-------|-------------|-------------|
| A: Scaling | M1.1 + S2.1 | 35 | ~12 saat |
| B: Ablation | M1.2 | 25 | ~8 saat |
| C: Sensitivity | M1.2 | 48 | ~16 saat |
| D: Saturation | S2.3 | 18 | ~6 saat |
| E: Info Age | S2.4 | 15 | ~5 saat |
| **TOPLAM** | | **141** | **~47 saat** |

---

## 7. S2.2 — OPENRMF KARŞILAŞTIRMASI

Bu deney, OpenRMF'nin kurulumuna ve aynı topolojide çalıştırılmasına bağlıdır. İki seçenek:

**Seçenek 1 (Önerilen):** OpenRMF'yi aynı Docker Compose ortamında çalıştır, aynı harita ve görev setini ver, aynı KPI'ları ölç. Salzillo [38]'ın sonuçlarını doğrudan tekrarlayıp genişlet.

**Seçenek 2 (Minimum):** Eğer OpenRMF çalıştırılamıyorsa, makaledeki iddiaları yumuşat ve "future work" olarak belirt. Bu durumda M1.3'teki dil yumuşatma ile birleştirilir.

---

## 8. NOTLAR

- Tüm deneyler **aynı donanımda** çalıştırılmalı (spesifikasyon raporda belirtilmeli)
- **Random seed** her deney için kaydedilmeli (tekrarlanabilirlik)
- **Warmup süresi** (5dk) veriden çıkarılmalı (transient effects)
- İstatistiksel raporlama: **mean ± std, median, p95, p99** (sadece mean yeterli değil)
- Grafiklerde **güven aralığı** (95% CI) veya **hata çubukları** (error bars) gösterilmeli
