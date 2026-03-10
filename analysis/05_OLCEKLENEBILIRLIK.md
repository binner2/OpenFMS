# OpenFMS Akademik Analiz Raporu — Bölüm 5: Ölçeklenebilirlik Analizi

**Yazar:** Bağımsız Kod Denetim Raporu
**Tarih:** 2026-03-10
**Kapsam:** Ölçeklenebilirlik darboğazları, deney tasarımı ve test stratejisi

---

## 5.1 Mevcut Ölçeklenebilirlik Profili

### 5.1.1 Asimptotik Karmaşıklık Analizi

| İşlem | Karmaşıklık | Açıklama |
|-------|------------|----------|
| `fetch_mex_data()` — state cache iterasyonu | O(N) per robot | N robot × O(N) = **O(N²) per cycle** |
| `fetch_mex_data()` — order iterasyonu | O(N) per robot | N robot × O(N) = **O(N²) per cycle** |
| `instant_actions.fetch_data()` — DB sorgusu | O(1) per robot | N robot × O(1) = O(N) per cycle (ancak I/O bound) |
| `verify_robot_fitness()` — find_nearest_node | O(K) per robot | N robot × K itinerary node = O(N×K) |
| `_handle_active_mex_conflict()` — priority compare | O(1) per conflict | Sabit — iyi |
| `compute_overall_throughput()` — analytics | O(120 × T) | T = toplam görev sayısı |
| Trafik kontrolü (conflict detection) | O(P²) | P = granted_nodes_map çakışan robotlar |
| `fm_shortest_paths()` — Dijkstra | O(E log V) | E kenar, V düğüm — harita boyutuna bağlı |

### 5.1.2 Deneysel Döngü Süresi Tahminleri

**Model:**
```
T_cycle = N × (T_fetch_mex + T_instant_actions + T_verify + T_decision + T_publish)

Burada:
  T_fetch_mex = 0.02 × N ms  (cache iterasyonu, N entry × 2 geçiş)
  T_instant_actions = 15 ms   (DB round-trip, cache yok)
  T_verify = 2 ms             (cache hit, find_nearest_node fallback dahil)
  T_decision = 5 ms           (conflict resolution, constant)
  T_publish = 3 ms            (MQTT publish + DB write, %10-15 döngüde)
```

| Robot Sayısı (N) | T_cycle Tahmini | Karar Gecikmesi | Kullanılabilirlik |
|:-:|:-:|:-:|:-:|
| 2 | 50ms | <100ms | Mükemmel |
| 10 | 250ms | <300ms | Mükemmel |
| 25 | 700ms | <800ms | İyi |
| 50 | 1.5s | <2s | Kabul edilebilir |
| 80 | 2.4s | <3s | Sınırda |
| 100 | 3.7s | <4s | Yetersiz (>2s hız robotlar için) |
| 200 | 12s | <15s | Kullanılamaz |
| 500 | 65s | >1dk | İmkansız |
| 1000 | 250s | >4dk | İmkansız |

### 5.1.3 Darboğaz Dağılımı (100 Robot)

```
Toplam döngü süresi: ~3.7s (tahmin)

fetch_mex_data O(N²):   2.0s  ██████████████████████░░░░░ 54%
instant_actions DB:      1.5s  ████████████████░░░░░░░░░░ 41%
verify_robot_fitness:    0.1s  █░░░░░░░░░░░░░░░░░░░░░░░░  3%
Karar + publish:         0.1s  █░░░░░░░░░░░░░░░░░░░░░░░░  3%
```

---

## 5.2 Ölçeklenebilirlik Katmanları

### Katman 1: Mevcut (0-80 robot)
```
Tek Python süreci → Tek MQTT broker → Tek PostgreSQL
Sıralı döngü → Her robot için full fleet scan
```
**Tavan:** ~80 robot (döngü süresi <3s)

### Katman 2: Optimizasyon (80-250 robot)
```
Tek Python süreci → Tek MQTT broker → Tek PostgreSQL
+ instant_actions cache
+ Fleet snapshot (1 kez/döngü)
+ find_nearest_node bypass (lastNodeId kullan)
```
**Gerekli değişiklikler:**
1. `instant_actions.py`'ye `self.cache` dict ekle (30 satır kod)
2. `fetch_mex_data()` sonucunu döngü başında 1 kez hesapla, her `manage_traffic()`'e parametre olarak geç
3. `verify_robot_fitness()` içinde `lastNodeId` boş değilse `find_nearest_node()` atlat

**Beklenen tavan:** ~250 robot (döngü süresi <2s)

### Katman 3: Paralelleştirme (250-500 robot)
```
Tek Python süreci + ThreadPool → Tek MQTT broker → PostgreSQL + PgBouncer
+ RobotContext genişletmesi (tüm shared state)
+ Immutable fleet snapshot
+ Asyncio MQTT publish
```
**Gerekli değişiklikler:**
1. `last_traffic_dict`, `temp_robot_delay_time`, `collision_tracker`, `robots_in_collision` → `RobotContext` veya per-cycle collect
2. ThreadPoolExecutor aktive et (zaten kod var)
3. MQTT publish'i async yap

**Beklenen tavan:** ~500 robot (döngü süresi <1s, 4 core ile)

### Katman 4: Zone Partitioning (500-2000 robot)
```
N Python süreci × (Lokal MQTT broker + Lokal DB)
+ Global koordinatör (Redis Streams / Kafka)
+ Cross-zone handoff protokolü
```
**Beklenen tavan:** ~2000 robot (her zone 200 robot, 10 zone)

### Katman 5: Distributed System (2000+ robot)
```
Kubernetes cluster
+ Microservice mimarisi
+ Event sourcing + CQRS
+ Dedicated conflict resolution service
```

---

## 5.3 Ölçeklenebilirlik Deneyleri Nasıl Tasarlanmalı?

### 5.3.1 Deney Değişkenleri

| Değişken | Tip | Aralık | Artış Stratejisi |
|----------|-----|--------|-------------------|
| **Robot sayısı (N)** | Bağımsız | 2, 5, 10, 25, 50, 100, 200 | Logaritmik artış |
| **Harita boyutu** | Bağımsız | 10, 25, 50, 100, 200 düğüm | Doğrusal artış |
| **Görev yoğunluğu** | Bağımsız | 0.1, 0.5, 1.0, 2.0 görev/robot/dk | Doğrusal artış |
| **Ağ gecikmesi** | Bağımsız | 0, 10, 50, 100, 500 ms | Logaritmik artış |
| **Paket kaybı oranı** | Bağımsız | %0, %1, %2, %5, %10 | Doğrusal artış |
| **Döngü süresi** | Bağımlı (yanıt) | Ölçülür | — |
| **Görev tamamlanma süresi** | Bağımlı (yanıt) | Ölçülür | — |
| **Çarpışma sayısı** | Bağımlı (yanıt) | Ölçülür | — |
| **Throughput** | Bağımlı (yanıt) | Ölçülür | — |

### 5.3.2 Robot Sayısı Belirleme Stratejisi

**Neden logaritmik artış?**

Robot sayısını 1, 2, 3, 4, 5... şeklinde artırmak verimsizdir. Ölçeklenebilirlik sorunları genellikle **üstel** olarak ortaya çıkar. Logaritmik artış:

```
N = [2, 5, 10, 25, 50, 100, 200, 500, 1000]
```

Her adımda ~2-2.5x artış. Bu strateji:
1. **Düşük N'lerde** hızlı baseline oluşturur
2. **Orta N'lerde** darboğaz tespiti sağlar
3. **Yüksek N'lerde** asimptotik davranışı gösterir

### 5.3.3 Harita Boyutu Etkisi

Harita boyutu, yol planlama maliyetini doğrudan etkiler:

| Harita Düğüm Sayısı | Dijkstra Maliyeti | Etki |
|:---:|:---:|:---:|
| 10 | <1ms | Yok denecek kadar |
| 50 | ~5ms | Düşük |
| 200 | ~20ms | Orta |
| 1000 | ~100ms | Yüksek |

**Deney önerisi:** Her robot sayısı için 3 farklı harita boyutu test edilmeli:
- **Küçük**: N/2 düğüm (yoğun trafik, sık çarpışma)
- **Orta**: 2N düğüm (dengeli)
- **Büyük**: 10N düğüm (seyrek trafik, uzun yollar)

### 5.3.4 Tekrar Sayısı ve İstatistiksel Güvenilirlik

Her deney konfigürasyonu için:
- **Minimum 5 tekrar** (farklı random seed)
- **Minimum 10 dakika çalışma** (kararlı durum analizi)
- **Raporlama:** ortalama, standart sapma, medyan, p5, p95, p99
- **Isınma süresi:** İlk 2 dakikayı at (transient effects)

---

## 5.4 Mevcut Deney Altyapısı Ne Sunuyor?

### 5.4.1 Mevcut Senaryo Çalıştırıcı (`FmInterface.py`)

```python
# 196 satır — minimal senaryo runner
# Predefined senaryolar:
# S1: Mutex Group Conflict (2 robot, C10-C11-C3)
# S2: No-swap Conflict (çeşitli waitpoint konfigürasyonları)
# S3: Charging Task Conflicts
# random: Otomatik graf + rastgele görevler
```

**Sınırlamalar:**
- Sabit 2-3 robot senaryoları — ölçeklenebilirlik testi yapılamaz
- Tek senaryo çalışır, karşılaştırma yapılamaz
- Sonuçlar yapılandırılmış formatta kaydedilmez
- Parametre sweep (grid search) desteği yok

### 5.4.2 Mevcut Robot Simülatörü (`FmRobotSimulator.py`)

```python
# 1328 satır — VDA 5050 uyumlu simülatör
# Simüle edilen özellikler:
# - Kinematik (konum, hız)
# - Batarya tüketimi
# - Eylem durumları (dock, pick, drop)
# - MQTT iletişimi
```

**Sınırlamalar:**
- Her simülatör instance'ı ayrı bir Python süreci
- 100 robot = 100 süreç = çok fazla kaynak tüketimi
- WiFi gecikme/kayıp simülasyonu yok
- Robot arızası simülasyonu yok

### 5.4.3 Mevcut Test Paketi (`conflict_test.py`)

```python
# 539 satır — 7 senaryo (S1-S7)
# S1: Same Target Conflict
# S2a-S2d: No-Swap Conflicts
# S3a-S3d: Swap Conflicts
# S4: Post-Resolution Continuation
# S5: Mutex Group Enforcement
# S6: Task Queueing Under Load
# S7: Low Battery Auto-Charge
```

**Sınırlamalar:**
- Mock-based — gerçek MQTT/DB yok
- Yalnızca mantık doğruluğu test edilir
- Performans/ölçeklenebilirlik testi yok
- Sürekli entegrasyon (CI) entegrasyonu yok

---

## 5.5 Sonuçlar Nasıl Kaydediliyor?

### 5.5.1 Mevcut Kayıt Mekanizmaları

| Kayıt Yeri | Format | İçerik | Kalıcılık |
|-----------|--------|--------|-----------|
| `logs/live_dashboard.txt` | Düz metin | Anlık filo durumu | Üzerine yazılır |
| `logs/FmLogHandler.log` | Log formatı | Tüm olaylar | Ekleme modu |
| `logs/result_snapshot_*.txt` | Düz metin | Periyodik durum | Ekleme |
| `logs/conflict_test_report.md` | Markdown | Test sonuçları | Tek seferlik |
| PostgreSQL `state` tablosu | SQL | Robot durumları | Kalıcı |
| PostgreSQL `orders` tablosu | SQL | Görev geçmişi | Kalıcı |
| In-memory `analytics_data` | Dict | Görev metrikleri | Volatile |
| In-memory `latency_data` | Dict | MQTT gecikmeleri | Volatile |

### 5.5.2 Mevcut Kayıt Mekanizmasının Yetersizlikleri

1. **Yapılandırılmış veri yok**: Sonuçlar düz metin — programatik analiz çok zor
2. **Deney metadata'sı yok**: Hangi konfigürasyonla çalıştırıldı? Kaç robot? Hangi harita?
3. **Tekrarlanabilirlik yok**: Random seed kaydedilmiyor
4. **Otomatik karşılaştırma yok**: İki deney arasında fark nasıl ölçülür?
5. **Volatile metrikler**: `analytics_data` ve `latency_data` süreç kapandığında kaybolur
6. **Zaman serisi verisi yok**: Anlık snapshot var, ama zaman içindeki değişim yok

---

## 5.6 Hangi Performans Metriklerine Göre Sonuçlar Elde Ediliyor?

### 5.6.1 Mevcut Metrikler

| Metrik | Hesaplama Yeri | Doğruluk |
|--------|---------------|----------|
| Robot başına ortalama görev süresi | `order.py:compute_average_execution_duration()` | ⚠️ Medyan var, p95/p99 yok |
| Genel throughput (görev/dk) | `order.py:compute_overall_throughput()` | ✅ Düzeltildi |
| Robot başına MQTT gecikme | `state.py:compute_robot_avg_latency()` | ✅ Doğru (NTP varsayımıyla) |
| Sistem ortalama gecikme | `state.py:compute_system_avg_latency()` | ✅ Doğru |
| Boşta kalma süresi | `FmScheduleHandler:compute_overall_idle_metrics()` | ⚠️ Hata/stuck ayrımı yok |
| Çarpışma sayısı | `FmTrafficHandler:collision_tracker` | ⚠️ İsim yanıltıcı (conflict ≠ collision) |
| Kümülatif gecikme | `FmScheduleHandler:calculate_completed_delays()` | ❌ Yanıltıcı formülasyon |

### 5.6.2 EKSİK Metrikler (Olması Gerekenler)

| Metrik | Neden Gerekli | Hesaplama |
|--------|---------------|-----------|
| **p50/p95/p99 döngü süresi** | Kuyruk gecikmesi (tail latency) tespiti | Döngü başı/sonu zaman damgası |
| **Robot kullanım oranı (%)** | Filo verimliliği | (görev süresi) / (toplam süre) × 100 |
| **Görev bekleme süresi** | Kuyruk performansı | Görev oluşturma → atama arası süre |
| **Deadlock sayısı** | Trafik yönetimi kalitesi | 2+ robot karşılıklı bekleme tespiti |
| **Throughput/robot** | Per-robot verimlilik | Toplam throughput / aktif robot sayısı |
| **Enerji verimliliği** | Batarya optimizasyonu | Görev başına ortalama batarya tüketimi |
| **Reroute oranı** | Yol planlama kalitesi | Reroute sayısı / toplam navigasyon |
| **Emir teslim süresi** | İletişim kalitesi | Order publish → robot ACK arası süre |
| **DB sorgu gecikmesi** | Altyapı performansı | Sorgu başı/sonu zaman damgası |
| **Bellek kullanımı** | Kaynak izleme | psutil ile periyodik ölçüm |
| **CPU kullanımı** | Kaynak izleme | psutil ile periyodik ölçüm |
| **MQTT mesaj kuyruğu derinliği** | Broker yükü | Broker istatistikleri |

---

## 5.7 Hangi Grafikler Çizdiriliyor? Yeterli mi?

### 5.7.1 Mevcut Grafikler

| Grafik | Tip | Kaynak | Yeterli mi? |
|--------|-----|--------|-------------|
| Robot başına ortalama gecikme | ASCII bar chart | `state.py:terminal_bar_chart()` | ❌ Yalnızca terminal |
| Sistem ortalama gecikme vs robot sayısı | ASCII bar chart | `state.py:compute_system_avg_latency()` | ❌ Tek nokta |
| Throughput vs zaman | (Hesaplanıyor ama çizdirilmiyor) | `order.py:compute_overall_throughput()` | ❌ Görselleştirme yok |
| Grid harita görselleştirme | PNG dosyası | `FmSimGenerator.py` | ✅ Statik harita için yeterli |

### 5.7.2 EKSİK Grafikler (Akademik Yayın İçin Zorunlu)

| Grafik | Tip | Neden Gerekli |
|--------|-----|---------------|
| **Döngü süresi vs robot sayısı** | Çizgi grafik (log-log) | O(N²) davranışını gösterir |
| **Throughput vs robot sayısı** | Çizgi grafik | Ölçeklenebilirlik tavanını gösterir |
| **CDF (Kümülatif Dağılım) — görev tamamlanma süresi** | CDF eğrisi | Kuyruk davranışını gösterir |
| **Heatmap — düğüm kullanım yoğunluğu** | 2D heatmap | Trafik darboğazlarını gösterir |
| **Box plot — robot başına metrik dağılımı** | Box-whisker | Outlier tespiti |
| **Zaman serisi — throughput, gecikme, CPU** | Multi-axis çizgi | Sistem davranışının zaman içindeki değişimi |
| **Scatter plot — gecikme vs robot sayısı** | Scatter + trend line | İstatistiksel korelasyon |
| **Radar chart — çok boyutlu performans profili** | Radar/Spider | Farklı konfigürasyonların karşılaştırması |
| **Violin plot — görev süresi dağılımı** | Violin | Bimodal dağılım tespiti (normal vs conflict) |
| **Gantt chart — robot görev zaman çizelgesi** | Gantt | Boşta kalma ve çakışma görselleştirmesi |

---

## 5.8 Sonuçları Nasıl Yorumlayacağız?

### 5.8.1 Yorumlama Framework'ü

**Amdahl Yasası bağlamında:**
```
Speedup = 1 / ((1 - P) + P/N)

P = paralelleştirilebilir oran
N = işlemci/thread sayısı
```

Eğer `fetch_mex_data` toplam sürenin %54'ünü oluşturuyorsa ve bu paralelleştirilemezse:
```
Maksimum speedup = 1 / (0.54 + 0.46/N)
N → ∞: Speedup = 1/0.54 = 1.85x
```

Bu, O(N²) darboğazını çözmeden **%85'ten fazla hızlanmanın imkansız** olduğunu gösterir.

### 5.8.2 Karar Kriterleri

| Metrik | Kabul Edilebilir | İyi | Mükemmel |
|--------|-----------------|-----|----------|
| Döngü süresi | <5s | <2s | <500ms |
| Throughput | >0.5 görev/robot/saat | >2 görev/robot/saat | >5 görev/robot/saat |
| Çarpışma oranı | <%5 karar döngüsü | <%1 | %0 |
| Robot kullanım oranı | >%50 | >%70 | >%85 |
| Emir teslim başarı oranı | >%99 | >%99.9 | >%99.99 |
| Gecikme p99 | <10s | <3s | <1s |
| Deadlock | <1/saat | <1/gün | 0 |

---

## 5.9 Projenin Başarı/Başarısızlık Kriterleri

### 5.9.1 Minimum Kabul Kriterleri (Pass/Fail)

| # | Kriter | Eşik | Ölçüm Yöntemi |
|---|--------|------|---------------|
| 1 | **Fiziksel çarpışma** | 0 (SIFIR) | collision_tracker (düzeltilmiş isimle) |
| 2 | **Döngü süresi** | <5s (N=100 robot) | Döngü zamanlama |
| 3 | **Görev tamamlanma** | >%95 başarı oranı | completed / (completed + failed) |
| 4 | **Deadlock** | <1/saat | 2+ robot karşılıklı bekleme |
| 5 | **Bellek sızıntısı** | <50 MB/saat artış | psutil periyodik ölçüm |
| 6 | **Crash** | 0 (24 saat içinde) | Süreç izleme |

### 5.9.2 Ölçeklenebilirlik Başarı Kriterleri

| Hedef | Başarılı | Kısmen Başarılı | Başarısız |
|-------|----------|-----------------|-----------|
| 100 robot | <2s döngü, >%95 throughput | <5s döngü, >%90 throughput | >5s veya <%90 |
| 200 robot | <3s döngü, >%90 throughput | <7s döngü, >%80 throughput | >7s veya <%80 |
| 500 robot | <2s döngü (zone), >%85 throughput | <5s döngü, >%75 throughput | >5s veya <%75 |
| 1000 robot | <1s döngü (multi-zone), >%80 throughput | <3s döngü, >%70 throughput | >3s veya <%70 |

### 5.9.3 Akademik Yayın Başarı Kriterleri

Bir akademik yayının kabul edilmesi için:

1. **Tekrarlanabilirlik**: Tüm deneyler, açıklanan parametrelerle tekrarlanabilir olmalıdır
2. **İstatistiksel anlamlılık**: Minimum 5 tekrar, güven aralığı (%95) raporlanmalıdır
3. **Karşılaştırma**: En az 1 baseline (mevcut durum) ve 1 iyileştirilmiş versiyon
4. **Ölçek çeşitliliği**: En az 4 farklı robot sayısı (N = 10, 50, 100, 200)
5. **Stres testi**: Sistemin kırılma noktasının gösterilmesi
6. **Ablation study**: Her optimizasyonun bireysel etkisinin ölçülmesi

---

## 5.10 Sonuç

OpenFMS'in ölçeklenebilirlik profili, **O(N²) `fetch_mex_data` darboğazı** ve **cache'siz `instant_actions` DB sorgusu** tarafından domine edilmektedir. Bu iki sorun çözülmeden:

- 100 robot bile güvenilir bir şekilde yönetilemez
- Akademik yayın için yeterli deney verisi üretilemez
- Endüstriyel kullanım söz konusu olamaz

Önerilen deney matrisi (5 robot sayısı × 3 harita boyutu × 5 tekrar = 75 deney) temel ölçeklenebilirlik profilini ortaya koyacaktır. Bu deneyler, mevcut Docker Compose altyapısıyla (simülatör robot sayısı artırılarak) gerçekleştirilebilir.
