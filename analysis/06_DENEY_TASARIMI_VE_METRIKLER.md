# OpenFMS Akademik Analiz Raporu — Bölüm 6: Deney Tasarımı, Metrikler ve Sonuç Yorumlama

**Yazar:** Bağımsız Kod Denetim Raporu
**Tarih:** 2026-03-10
**Kapsam:** Ölçeklenebilir deney çerçevesi, performans metrikleri, grafik önerileri

---

## 6.1 Deneyleri Çalıştırmak İçin Mevcut Altyapı

### 6.1.1 Docker Compose Tabanlı Ortam

```yaml
# docker-compose.yml mevcut servisleri:
services:
  mqtt:       # Mosquitto broker
  db:         # PostgreSQL 13
  manager:    # FmMain.py (Fleet Manager)
  simulator:  # FmRobotSimulator.py (tek instance)
  scenario:   # FmInterface.py (senaryo çalıştırıcı)
  dashboard:  # Live dashboard viewer
```

**Mevcut çalıştırma:**
```bash
docker compose build
docker compose up -d
docker compose logs -f scenario
```

**Sınırlamalar:**
1. `simulator` servisi tek instance — birden fazla robot için `docker compose scale simulator=N` desteklenmiyor (her instance aynı konfigürasyonu okur)
2. Robot sayısı `FmRobotSimulator.py` içinde hardcoded `config/robots.yaml`'dan okunur
3. Senaryo otomasyonu `FmInterface.py` ile sınırlı (S1, S2, S3, random)
4. Sonuç toplama otomatik değil — log dosyalarından manuel okuma gerekir

### 6.1.2 Mevcut Senaryo Repertuarı

| Senaryo | Robot | Düğüm | Test Edilen | Süre |
|---------|-------|-------|-------------|------|
| S1 | 2 | 7 | Mutex group conflict | ~3dk |
| S2 | 2 | 7 | No-swap conflict | ~3dk |
| S3 | 2 | 7 | Charging conflict | ~3dk |
| random | N (config) | M (config) | Rastgele görevler | Belirsiz |

### 6.1.3 Mevcut Veri Toplama

```
Kaynaklar:
1. logs/live_dashboard.txt     → Anlık durum (üzerine yazılır)
2. logs/FmLogHandler.log       → Tüm olaylar (append)
3. logs/result_snapshot_*.txt  → Periyodik snapshot'lar
4. PostgreSQL tables           → state, orders, connection, instant_actions
5. In-memory analytics_data    → Görev metrikleri (volatile)
6. In-memory latency_data      → MQTT gecikmeleri (volatile)
```

---

## 6.2 Önerilen Deney Çerçevesi

### 6.2.1 Otomatik Deney Orkestratörü (Tasarım)

```python
# experiment_runner.py — Önerilen yapı
class ExperimentConfig:
    """Tek bir deney konfigürasyonu."""
    robot_count: int          # 2, 5, 10, 25, 50, 100, 200
    map_node_count: int       # 10, 25, 50, 100
    task_rate: float          # görev/robot/dakika
    network_latency_ms: int   # 0, 10, 50, 100, 500
    packet_loss_percent: float # 0.0, 0.01, 0.02, 0.05
    duration_minutes: int     # 10, 20, 30
    random_seed: int          # Tekrarlanabilirlik için
    warmup_minutes: int       # İlk N dakikayı at
    repeat_id: int            # 1-5 (tekrar numarası)

class ExperimentResult:
    """Deney sonuçları — yapılandırılmış."""
    config: ExperimentConfig
    start_time: datetime
    end_time: datetime

    # Zaman serileri
    cycle_times: List[float]           # Her döngü süresi (ms)
    throughput_per_minute: List[float]  # Dakika başına tamamlanan görev
    latency_per_minute: List[float]    # Dakika başına ortalama gecikme

    # Toplu metrikler
    total_tasks_completed: int
    total_tasks_failed: int
    total_conflicts: int
    total_deadlocks: int
    total_reroutes: int
    total_collisions: int

    # Per-robot metrikler
    per_robot_utilization: Dict[str, float]
    per_robot_avg_task_time: Dict[str, float]
    per_robot_idle_time: Dict[str, float]

    # Kaynak kullanımı
    peak_memory_mb: float
    avg_cpu_percent: float
    db_query_count: int
    mqtt_messages_sent: int
    mqtt_messages_lost: int

class ExperimentRunner:
    """Deney matrisini otomatik çalıştırır."""

    def run_matrix(self, configs: List[ExperimentConfig]):
        results = []
        for config in configs:
            print(f"Running: N={config.robot_count}, "
                  f"Map={config.map_node_count}, "
                  f"Seed={config.random_seed}")

            # 1. Harita oluştur
            self.generate_map(config)
            # 2. Docker servisleri başlat
            self.start_services(config)
            # 3. Isınma süresini bekle
            time.sleep(config.warmup_minutes * 60)
            # 4. Veri toplamayı başlat
            collector = DataCollector(config)
            collector.start()
            # 5. Deney süresini bekle
            time.sleep(config.duration_minutes * 60)
            # 6. Veri toplamayı durdur
            result = collector.stop()
            results.append(result)
            # 7. Servisleri durdur
            self.stop_services()
            # 8. Sonuçları kaydet
            self.save_result(result)

        return results
```

### 6.2.2 Deney Matrisi

**Tam Faktöriyel Deney Tasarımı:**

```
Robot sayıları:     [2, 10, 25, 50, 100, 200]     = 6 seviye
Harita boyutları:   [küçük(N/2), orta(2N), büyük(10N)] = 3 seviye
Tekrar sayısı:      5

Toplam deney:       6 × 3 × 5 = 90 deney
Deney başına süre:  15 dakika (5dk ısınma + 10dk veri)
Toplam süre:        90 × 15dk = 22.5 saat
```

**Ağ koşulları deney seti (ayrı):**
```
Gecikme (ms):       [0, 50, 100, 500]             = 4 seviye
Paket kaybı (%):    [0, 1, 5, 10]                 = 4 seviye
Robot sayısı:       [10, 50]                       = 2 seviye (sabit)
Tekrar:             3

Toplam:             4 × 4 × 2 × 3 = 96 deney
Süre:               96 × 15dk = 24 saat
```

---

## 6.3 Performans Metrikleri — Detaylı Tanımlar

### 6.3.1 Birincil Metrikler (KPI)

**M1: Döngü Süresi (Cycle Time)**
```
Tanım:    manage_robot() çağrısının toplam süresi, tüm robotlar için
Birim:    Milisaniye (ms)
Formül:   T_cycle = t_end_loop - t_start_loop
Raporlama: mean, median, p95, p99, max
Hedef:    <2000ms (100 robot)
```

**M2: Görev Throughput**
```
Tanım:    Birim zamanda tamamlanan görev sayısı
Birim:    Görev/dakika
Formül:   Throughput = completed_tasks / duration_minutes
Raporlama: Zaman serisi (dakika bazında) + toplam
Hedef:    >0.5 × N × task_rate (N robot, task_rate=görev oranı)
```

**M3: Görev Tamamlanma Oranı**
```
Tanım:    Başarıyla tamamlanan görevlerin oranı
Birim:    Yüzde (%)
Formül:   Rate = completed / (completed + failed + timeout) × 100
Raporlama: Toplam + robot bazında
Hedef:    >%95
```

**M4: Robot Kullanım Oranı (Utilization)**
```
Tanım:    Robotun görev üzerinde çalıştığı sürenin oranı
Birim:    Yüzde (%)
Formül:   U = (total_time - idle_time - charging_time) / total_time × 100
Raporlama: Robot bazında + filo ortalaması
Hedef:    >%60
```

### 6.3.2 İkincil Metrikler

**M5: Çarpışma/Conflict Oranı**
```
Tanım:    Trafik çakışması yaşayan karar döngüsü oranı
Birim:    Yüzde (%)
Formül:   Rate = conflict_cycles / total_cycles × 100
Raporlama: Toplam + düğüm bazında heatmap
```

**M6: Emir Teslim Gecikmesi**
```
Tanım:    Order publish → robot state'te orderId değişikliği arası süre
Birim:    Milisaniye (ms)
Formül:   Latency = t_ack - t_publish
Raporlama: mean, median, p95, p99
```

**M7: Reroute Oranı**
```
Tanım:    Yeniden rotalama gereken navigasyon oranı
Birim:    Yüzde (%)
Formül:   Rate = reroute_count / total_navigation_count × 100
```

**M8: Deadlock Süresi**
```
Tanım:    2+ robotun karşılıklı beklediği süre
Birim:    Saniye
Formül:   Kümülatif deadlock süresi / deney süresi
```

### 6.3.3 Sistem Metrikleri

**M9: Bellek Kullanımı**
```
Tanım:    Fleet Manager sürecinin RSS bellek kullanımı
Birim:    Megabyte (MB)
Formül:   psutil.Process().memory_info().rss / 1024 / 1024
Raporlama: Zaman serisi (30sn aralıklarla)
```

**M10: CPU Kullanımı**
```
Tanım:    Fleet Manager sürecinin CPU kullanım oranı
Birim:    Yüzde (%)
Formül:   psutil.Process().cpu_percent(interval=1.0)
Raporlama: Zaman serisi
```

**M11: DB Sorgu Gecikmesi**
```
Tanım:    PostgreSQL sorgu başlangıç-bitiş arası süre
Birim:    Milisaniye (ms)
Raporlama: Sorgu tipi bazında (SELECT, INSERT, UPDATE)
```

---

## 6.4 Önerilen Grafikler

### 6.4.1 Temel Ölçeklenebilirlik Grafikleri

**Grafik 1: Döngü Süresi vs Robot Sayısı (Log-Log)**
```
Y ekseni: Döngü süresi (ms) — logaritmik
X ekseni: Robot sayısı (N) — logaritmik
Çizgiler: Mevcut (O(N²)), Optimized (O(N)), Hedef (<2s)
Amaç:     O(N²) davranışını görsel olarak kanıtlamak
Beklenen: Düz çizgi (eğim=2) → optimizasyon sonrası eğim=1
```

**Grafik 2: Throughput vs Robot Sayısı**
```
Y ekseni: Throughput (görev/dakika)
X ekseni: Robot sayısı (N)
Çizgiler: Mevcut, Optimized, İdeal (doğrusal artış)
Amaç:     Ölçeklenebilirlik tavanını göstermek
Beklenen: Mevcut → düzleşen eğri (saturation), Optimized → doğrusala yakın
```

**Grafik 3: CDF — Görev Tamamlanma Süresi**
```
Y ekseni: Kümülatif olasılık (0-1)
X ekseni: Görev tamamlanma süresi (s)
Çizgiler: N=10, N=50, N=100, N=200
Amaç:     Kuyruk davranışını göstermek (p95, p99)
Beklenen: N arttıkça kuyruk uzar (daha fazla conflict)
```

**Grafik 4: Heatmap — Düğüm Kullanım Yoğunluğu**
```
Eksenler: Harita düğümleri (x, y koordinatları)
Renk:     Düğümden geçen robot sayısı (sıcak=yoğun)
Amaç:     Trafik darboğazlarını görsel tespit
Beklenen: Koridor düğümleri "sıcak", kenar düğümler "soğuk"
```

### 6.4.2 Karşılaştırma Grafikleri

**Grafik 5: Box Plot — Robot Başına Görev Süresi Dağılımı**
```
Y ekseni: Görev tamamlanma süresi (s)
X ekseni: Robot ID
Amaç:     Outlier ve adaletsiz iş dağılımı tespiti
Beklenen: Bazı robotlar sürekli yavaş (dock'a uzak, çok conflict)
```

**Grafik 6: Ablation Study — Her Optimizasyonun Bireysel Etkisi**
```
Y ekseni: Döngü süresi iyileşmesi (%)
X ekseni: Optimizasyon adımları
Barlar:   [Baseline, +IA Cache, +Fleet Snapshot, +ThreadPool, +AsyncIO]
Amaç:     Her değişikliğin bireysel katkısını ölçmek
```

### 6.4.3 Zaman Serisi Grafikleri

**Grafik 7: Multi-Axis — Sistem Sağlık Dashboard'u**
```
Y1 (sol):  Döngü süresi (ms)
Y2 (sağ):  Bellek kullanımı (MB)
X ekseni:  Zaman (dakika)
Ek çizgi:  Throughput (görev/dk)
Amaç:      Bellek sızıntısı ve performans degradasyonu tespiti
```

**Grafik 8: Gantt Chart — Robot Görev Zaman Çizelgesi**
```
Y ekseni:  Robot ID
X ekseni:  Zaman
Renkler:   Yeşil=görev, Sarı=bekleme, Kırmızı=çarpışma, Gri=boşta
Amaç:      Filo koordinasyonu görselleştirmesi
```

### 6.4.4 Ağ Performans Grafikleri

**Grafik 9: Gecikme vs Paket Kaybı Oranı**
```
Y ekseni: Ortalama emir teslim gecikmesi (ms)
X ekseni: Paket kaybı oranı (%)
Çizgiler: QoS 0, QoS 1, QoS 1 + ACK
Amaç:     WiFi kalitesinin sistem performansına etkisini göstermek
```

**Grafik 10: Violin Plot — Farklı Ağ Koşullarında Görev Süresi Dağılımı**
```
Y ekseni: Görev süresi (s)
X ekseni: Ağ koşulu (ideal, %1 kayıp, %5 kayıp, %10 kayıp)
Amaç:     Ağ kalitesinin görev performansına etkisinin dağılımı
```

---

## 6.5 Sonuçları Nasıl Yorumlayacağız?

### 6.5.1 İstatistiksel Analiz Çerçevesi

**Adım 1: Normallik Testi**
```
Her metrik için Shapiro-Wilk testi (n<50) veya Anderson-Darling testi (n≥50)
Eğer p < 0.05 → non-parametrik testler kullan
Eğer p ≥ 0.05 → parametrik testler kullanılabilir
```

**Adım 2: Etki Büyüklüğü (Effect Size)**
```
Cohen's d = (mean1 - mean2) / pooled_std_dev
d < 0.2  → ihmal edilebilir fark
d = 0.2-0.5 → küçük fark
d = 0.5-0.8 → orta fark
d > 0.8  → büyük fark
```

**Adım 3: Güven Aralıkları**
```
%95 güven aralığı: mean ± 1.96 × (std / √n)
Grafilerde hata çubukları (error bars) olarak göster
```

### 6.5.2 Yorumlama Şablonları

**Ölçeklenebilirlik yorumu:**
```
"N=100 robotla, ortalama döngü süresi X.XX ± Y.YY ms olarak ölçülmüştür
(95% CI: [A, B], n=5 tekrar). Bu, N=50'deki Z.ZZ ms'ye kıyasla %PP artışa
karşılık gelmektedir (Cohen's d = D.DD, büyük etki). O(N²) asimptotik model
ile tutarlıdır (R² = 0.XX)."
```

**Optimizasyon yorumu:**
```
"instant_actions cache eklenmesi, N=100 robotla döngü süresini X.XX ms'den
Y.YY ms'ye düşürmüştür (%PP iyileşme, p < 0.001, n=5). Bu iyileşme,
darboğazın %QQ'sının I/O-bound olduğu hipotezini desteklemektedir."
```

### 6.5.3 Ortam Hazırlığı

**Donanım gereksinimleri (simülasyon ortamı):**

| Robot Sayısı | RAM | CPU Çekirdek | Disk | Ağ |
|:---:|:---:|:---:|:---:|:---:|
| 10 | 4 GB | 2 | 10 GB | Localhost |
| 50 | 8 GB | 4 | 20 GB | Localhost |
| 100 | 16 GB | 8 | 50 GB | Localhost |
| 200 | 32 GB | 16 | 100 GB | Localhost veya LAN |
| 500+ | 64 GB | 32 | 200 GB | LAN (ayrı makineler) |

**Yazılım ortamı:**
```
Docker Engine >= 24.0
Docker Compose >= 2.20
Python 3.9+
PostgreSQL 13+
Mosquitto 2.x

Deney yalıtımı:
- Her deney temiz container'larla başlar
- PostgreSQL tabloları her deney başında sıfırlanır
- MQTT broker session'ları temizlenir
- Random seed kaydedilir
```

### 6.5.4 Robot Ölçeği ve Artırma Stratejisi

```
Faz 1 (Doğrulama):     N = 2, 5, 10
  → Temel fonksiyonellik doğrulaması
  → Her senaryonun (S1-S7) geçtiğini teyit et

Faz 2 (Baseline):      N = 25, 50
  → Performans baseline'ı oluştur
  → O(N²) davranışını doğrula

Faz 3 (Stres):          N = 100, 200
  → Sistem kırılma noktasını bul
  → Darboğaz profilini çıkar

Faz 4 (Optimizasyon):  N = 100, 200 (optimizasyonlar ile)
  → Her optimizasyonun etkisini ölç
  → Ablation study yap

Faz 5 (Ölçek):         N = 500, 1000 (zone-partitioned)
  → Mimari değişikliğin etkisini ölç
  → Üretim ölçeğine yaklaşım
```

**Bu artırma yeterli midir?**

Hayır, tam bir değerlendirme için ek boyutlar gerekir:
1. **Görev tipi çeşitliliği**: Salt transport, salt charge, karışık (%70/%20/%10)
2. **Harita karmaşıklığı**: Tek koridor, grid, labirent
3. **Arıza enjeksiyonu**: Robot arızası, broker arızası, DB arızası
4. **Zaman bazlı stres**: 1 saat, 4 saat, 24 saat (bellek sızıntısı tespiti)

---

## 6.6 Proje Başarı/Başarısızlık Karar Kriterleri

### 6.6.1 Mutlak Başarı Kriterleri (Go/No-Go)

| Kriter | Başarılı | Başarısız |
|--------|----------|-----------|
| Fiziksel çarpışma (collision_tracker) | 0 (tüm deneylerde) | ≥1 |
| 24 saat kesintisiz çalışma | Crash yok | ≥1 crash |
| VDA 5050 uyumluluk | Tüm mesaj tipleri doğru | Uyumsuzluk var |
| Görev tamamlanma oranı (N=50) | ≥%95 | <%95 |
| Bellek sızıntısı (24 saat) | <100 MB artış | ≥100 MB artış |

### 6.6.2 Göreceli Başarı Kriterleri (Ölçeklenebilirlik)

| Kriter | A (Mükemmel) | B (İyi) | C (Kabul edilir) | F (Başarısız) |
|--------|:---:|:---:|:---:|:---:|
| 100 robot döngü süresi | <1s | <2s | <5s | ≥5s |
| 200 robot döngü süresi | <2s | <5s | <10s | ≥10s |
| Throughput doğrusallığı | R²>0.9 | R²>0.7 | R²>0.5 | R²≤0.5 |
| Conflict çözüm başarısı | >%99 | >%95 | >%90 | ≤%90 |
| Optimizasyon etkisi | >%50 iyileşme | >%30 | >%10 | ≤%10 |

### 6.6.3 Akademik Yayın Hazırlık Seviyesi

| Seviye | Tanım | Gereksinimler |
|--------|-------|---------------|
| **TRL-1** | Temel araştırma | Konsept kanıtlanmış, 2-5 robot |
| **TRL-2** | Teknoloji formülasyonu | 10-25 robot, tekrarlanabilir deneyler |
| **TRL-3** | Kavram kanıtı | 50-100 robot, istatistiksel analiz |
| **TRL-4** | Laboratuvar doğrulama | 100+ robot, ablation study, karşılaştırma |
| **TRL-5** | Simülasyon doğrulama | 200+ robot, stres testi, arıza testi |
| **TRL-6** | Gerçek ortam prototipi | Gerçek robotlarla doğrulama |

**Mevcut durum:** TRL-2 (10-25 robot simülasyonla çalışıyor, tekrarlanabilirlik sınırlı)
**Hedef:** TRL-4 (akademik yayın için minimum gereksinim)

---

## 6.7 Sonuç

Mevcut deney altyapısı, **prototip doğrulama** (TRL-1/2) için yeterli ancak **akademik yayın** (TRL-4) için yetersizdir. Eksikler:

1. **Otomatik deney orkestratörü** — Manuel çalıştırma 90+ deney için pratik değil
2. **Yapılandırılmış sonuç kaydetme** — JSON/CSV çıktısı gerekli (düz metin değil)
3. **İstatistiksel analiz pipeline** — Otomatik güven aralığı, etki büyüklüğü hesaplama
4. **Grafik üretim sistemi** — matplotlib/plotly ile otomatik grafik üretimi
5. **Ağ koşulu simülasyonu** — tc (traffic control) ile gecikme/kayıp enjeksiyonu
6. **Kaynak izleme** — psutil ile otomatik CPU/bellek takibi

Bu eksiklerin giderilmesi, **projenin akademik değerini dramatik olarak artıracaktır**.
