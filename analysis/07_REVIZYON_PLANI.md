# OpenFMS Akademik Analiz Raporu — Bölüm 7: Kapsamlı Revizyon Planı

**Yazar:** Bağımsız Kod Denetim Raporu
**Tarih:** 2026-03-10
**Kapsam:** WiFi paketinin ve tüm sistemin sıfırdan nasıl yazılması gerektiğinin detaylı planı

---

## 7.1 "Ben Olsam Nasıl Yazardım?" — Temel Tasarım Kararları

### 7.1.1 Hangi Hataları Tekrarlamam?

| # | Mevcut Hata | Yapmazdım Çünkü | Yerine Ne Yapardım |
|---|-------------|------------------|---------------------|
| 1 | QoS 0 ile kritik mesaj gönderimi | Mesaj kaybı → fiziksel çarpışma | QoS 1 + uygulama seviyesi ACK |
| 2 | String birleştirme ile SQL | SQL injection riski | Parameterized queries + ORM |
| 3 | Global mutable state (cache dict) | Race condition | Immutable snapshot pattern |
| 4 | fetch_mex_data O(N²) | Ölçeklenemez | Event-driven traffic map |
| 5 | Tek monolitik dosya (2734 satır) | Bakım imkansız | Modüler mimari, dosya başına <300 satır |
| 6 | Exception yutma | Sessiz arıza | Structured error handling + alerting |
| 7 | Sınırsız bellek büyümesi | OOM crash | Bounded collections + TTL |
| 8 | Type annotation yokluğu | Runtime hata tespiti imkansız | Type hints + mypy strict mode |
| 9 | Birim test yokluğu | Regresyon riski | %80+ test coverage |
| 10 | Hardcoded konfigürasyon | Esneklik yok | Environment-based config + validation |

### 7.1.2 Mimari İlkeler

```
1. SEPARATION OF CONCERNS (Endişelerin Ayrılması)
   ├─ Communication Layer (MQTT, mesaj codec)
   ├─ State Management Layer (event-driven, immutable snapshot)
   ├─ Decision Layer (conflict resolution, task assignment)
   ├─ Persistence Layer (DB abstraction)
   └─ Monitoring Layer (metrics, logging, alerting)

2. IMMUTABILITY BY DEFAULT (Varsayılan Değişmezlik)
   ├─ Fleet snapshot her döngü başında alınır
   ├─ Snapshot döngü içinde değiştirilemez
   └─ Kararlar snapshot'a dayanır, canlı veriye değil

3. FAIL-SAFE (Güvenli Başarısızlık)
   ├─ Şüphe durumunda robotu durdur
   ├─ Bilinmeyen durum = tehlike
   └─ Her hata açıkça loglanır ve alert üretir

4. OBSERVABLE (Gözlemlenebilir)
   ├─ Her karar gerekçesiyle loglanır
   ├─ Prometheus metrikleri
   └─ Distributed tracing (OpenTelemetry)
```

---

## 7.2 Faz 1: Acil Düzeltmeler (1-2 Hafta)

**Amaç:** Mevcut kodu kırmadan kritik bugları düzelt.

### 7.2.1 SQL Injection Düzeltmesi

**Dosyalar:** Tüm submodüller (`state.py`, `connection.py`, `order.py`, `instant_actions.py`, `factsheet.py`)

**Neden:** SQL injection, endüstriyel yazılımda en temel güvenlik açığıdır. Bu düzeltme, hiçbir fonksiyonel değişiklik gerektirmez — yalnızca string birleştirme → parameterized query dönüşümü.

**Değişiklik:** Tüm `"DROP TABLE IF EXISTS "+self.table_*` → `sql.SQL("DROP TABLE IF EXISTS {}").format(sql.Identifier(self.table_*))`
Tüm `f"SELECT ... WHERE datname = '{dbname}'"` → parameterized query

### 7.2.2 Tanımsız Değişken Düzeltmeleri

**Dosyalar:** `state.py:fetch_data`, `FmTrafficHandler.py:check_available_last_mile_dock`

**Neden:** Bu hatalar deterministik crash'lere yol açar. BUG-02 (tanımsız değişken) ve BUG-09 (tanımsız ctx) acil düzeltilmelidir.

**Değişiklik:**
- `state.py:fetch_data` → Fonksiyon başında default değerler tanımla
- `check_available_last_mile_dock` → `ctx` parametresini fonksiyon imzasına ekle

### 7.2.3 Parametre Uyumsuzluğu Düzeltmesi

**Dosya:** `FmTrafficHandler.py:562`

**Neden:** BUG-08 — `_handle_last_mile_conflict_case` çağrısında ctx, task_dict yerine geçiyor.

**Değişiklik:** `ctx` keyword argüman olarak geçirilecek.

### 7.2.4 Cursor Kapatma Düzeltmeleri

**Dosyalar:** Tüm submodüller

**Neden:** Bellek sızıntısı. Her cursor `try/finally` veya `with` bloğuna alınacak.

### 7.2.5 QoS Seviye Yükseltmesi

**Dosyalar:** `state.py:168`, tüm publish fonksiyonları

**Neden:** QoS 0 → QoS 1 geçişi, tek satırlık değişiklik ama güvenilirlik açısından devasa etki.

**Değişiklik:**
```python
# order.py ve instant_actions.py'de publish fonksiyonları:
mqtt_client.publish(topic, message, qos=1, retain=False)  # qos=0 → qos=1
```

---

## 7.3 Faz 2: İletişim Katmanı Yeniden Tasarımı (2-3 Hafta)

**Amaç:** WiFi haberleşmesini endüstriyel kaliteye çıkar.

### 7.3.1 Güvenilir Mesaj Katmanı

**Yeni dosya:** `communication/reliable_publisher.py`

**Neden:** QoS 1 tek başına yeterli değildir. Uygulama seviyesinde ACK mekanizması, emir teslimini garanti eder.

**İçerik:**
- ACK/timeout/retry mekanizması
- Exponential backoff
- Dead letter queue (ulaştırılamayan emirler)
- Emir teslim metrikleri

### 7.3.2 MQTT Bağlantı Yöneticisi

**Yeni dosya:** `communication/mqtt_manager.py`

**Neden:** Mevcut kodda MQTT bağlantısı FmMain.py içinde inline yönetiliyor. Roaming, reconnect, TLS gibi endişeler ayrı bir katmanda olmalıdır.

**İçerik:**
- TLS 1.3 desteği
- Otomatik reconnect (exponential backoff)
- Bağlantı sağlık izleme
- Multi-broker failover
- Topic yönetimi ve subscription tracking

### 7.3.3 Mesaj Codec

**Yeni dosya:** `communication/vda5050_codec.py`

**Neden:** JSON serialization/deserialization her yerde tekrarlanıyor. Tek bir codec, tutarlılık ve performans sağlar.

**İçerik:**
- VDA 5050 mesaj tipleri (state, order, connection, factsheet, instantActions)
- Schema validation (mevcut jsonschema kullanımını merkezileştir)
- Delta encoding desteği
- Mesaj sıkıştırma (msgpack veya protobuf opsiyonu)

### 7.3.4 WiFi Sağlık İzleme

**Yeni dosya:** `communication/network_monitor.py`

**Neden:** WiFi kalitesi doğrudan sistem güvenilirliğini etkiler. Proaktif izleme, sorunları ortaya çıkmadan önce tespit eder.

**İçerik:**
- MQTT round-trip gecikme ölçümü
- Paket kaybı oranı hesaplama
- Broker yanıt süresi izleme
- Adaptif QoS (ağ kalitesine göre QoS seviyesi değiştirme)

---

## 7.4 Faz 3: State Management Yeniden Tasarımı (2-3 Hafta)

**Amaç:** Race condition'ları ortadan kaldır, O(N²) → O(N) dönüşümü yap.

### 7.4.1 Event-Driven Traffic Map

**Yeni dosya:** `state/traffic_map.py`

**Neden:** Mevcut `fetch_mex_data()` her döngüde tüm filoyu O(N) tarar, N robot için O(N²). Event-driven traffic map, MQTT callback'lerinde O(1) güncelleme yapar.

**İçerik:**
- Thread-safe TrafficMap sınıfı
- MQTT callback'ten otomatik güncelleme
- O(1) düğüm müsaitlik kontrolü
- Snapshot oluşturma (her döngü başında)

### 7.4.2 Immutable Fleet Snapshot

**Yeni dosya:** `state/fleet_snapshot.py`

**Neden:** Race condition'ların kök nedeni, döngü sırasında verinin değişebilmesidir. Immutable snapshot, tüm kararların tutarlı veriye dayanmasını garanti eder.

**İçerik:**
```python
@dataclass(frozen=True)
class RobotState:
    robot_id: str
    position: Tuple[float, float, float]
    base_node: str
    horizon: Tuple[str, ...]
    battery_percent: float
    is_driving: bool
    errors: Tuple[str, ...]
    timestamp: float

@dataclass(frozen=True)
class FleetSnapshot:
    timestamp: float
    robots: Dict[str, RobotState]  # frozen dict
    node_occupancy: Dict[str, str]  # node → robot
    pending_orders: Dict[str, Order]
    active_conflicts: Set[Tuple[str, str]]
```

### 7.4.3 instant_actions Cache

**Dosya:** `submodules/instant_actions.py`

**Neden:** Her döngüde her robot için DB sorgusu → N × 15ms = 1.5s (N=100). Cache ile bu 0ms olur.

**Değişiklik:** `OrderPublisher.cache` pattern'ını kopyala:
```python
self.cache: dict = {}  # {r_id: latest_action_record}

def process_published_action(self, robot_id, action):
    self.cache[robot_id] = action
```

### 7.4.4 Bounded Collections

**Yeni dosya:** `utils/bounded_collections.py`

**Neden:** Bellek sızıntılarını yapısal olarak önle.

**İçerik:**
```python
class BoundedDict:
    """Maksimum boyut aşılınca en eski girdileri silen dict."""

class TTLDict:
    """Belirli süre sonra otomatik expire olan dict."""

class SlidingWindowMetric:
    """Sabit pencere boyutlu metrik toplayıcı."""
```

---

## 7.5 Faz 4: Trafik Yönetimi Refactoring (3-4 Hafta)

**Amaç:** 2734 satırlık monoliti, test edilebilir modüllere böl.

### 7.5.1 Modül Yapısı

```
traffic/
├── __init__.py
├── conflict_detector.py      # Çarpışma tespiti (200 satır)
├── conflict_resolver.py      # Çarpışma çözümü (300 satır)
├── mutex_manager.py          # Mutex group yönetimi (100 satır)
├── node_reservation.py       # Düğüm rezervasyonu (200 satır)
├── rerouter.py               # Yeniden rotalama (300 satır)
├── priority_negotiator.py    # Öncelik müzakeresi (200 satır)
└── traffic_analytics.py      # Trafik analitiği (150 satır)
```

### 7.5.2 Neden Bu Ayrım?

| Mevcut | Sorun | Yeni Modül | Neden |
|--------|-------|-----------|-------|
| `fetch_mex_data` (511 satır) | Veri çekme + parsing + trafik + analytics | `fleet_snapshot.py` + `traffic_map.py` | Tek sorumluluk |
| `_handle_active_mex_conflict` (220 satır) | Müzakere + güncelleme + publish | `priority_negotiator.py` + `node_reservation.py` | Endişelerin ayrılması |
| `reroute_robot` + yardımcılar (200 satır) | Rota hesaplama + itinerary güncelleme | `rerouter.py` | Saf fonksiyon olabilir |
| `collision_tracker` logic (50 satır) | Analytics kodu trafik kodu içinde | `traffic_analytics.py` | Metrics ayrı katman |

### 7.5.3 RobotContext Genişletmesi

**Dosya:** `traffic/robot_context.py`

**Neden:** Mevcut `RobotContext` temel verileri içeriyor ama `temp_robot_delay_time`, `collision_tracker`, `last_traffic_dict` hâlâ FmTrafficHandler instance state'inde.

**Değişiklik:** Tüm per-robot geçici durum RobotContext'e taşınacak. Fleet-wide durum (collision_tracker) per-cycle collector pattern'a geçecek:

```python
@dataclass
class CycleMetrics:
    """Her döngüde sıfırdan oluşturulur, döngü sonunda toplu kaydedilir."""
    new_conflicts: int = 0
    resolved_conflicts: int = 0
    reroutes: int = 0
    orders_published: int = 0
    cycle_start_time: float = 0
    cycle_end_time: float = 0
```

---

## 7.6 Faz 5: Test Altyapısı (2-3 Hafta)

**Amaç:** %80+ test coverage, CI/CD entegrasyonu.

### 7.6.1 Test Stratejisi

```
tests/
├── unit/
│   ├── test_conflict_detector.py
│   ├── test_conflict_resolver.py
│   ├── test_mqtt_manager.py
│   ├── test_traffic_map.py
│   ├── test_fleet_snapshot.py
│   ├── test_fuzzy_dispatcher.py
│   ├── test_reliable_publisher.py
│   └── test_bounded_collections.py
├── integration/
│   ├── test_mqtt_communication.py
│   ├── test_db_operations.py
│   ├── test_end_to_end_scenario.py
│   └── test_scenarios_S1_S7.py    # Mevcut conflict_test.py geçişi
├── performance/
│   ├── test_scalability.py
│   ├── test_memory_leaks.py
│   └── test_network_resilience.py
└── conftest.py                    # Paylaşılan fixtures
```

### 7.6.2 Neden Bu Testler?

| Test | Neyi Yakalar | Örnek |
|------|-------------|-------|
| `test_conflict_detector` | Çarpışma tespitindeki mantık hataları | İki robotun aynı düğümde tespiti |
| `test_traffic_map` | Race condition, thread safety | Concurrent update + snapshot |
| `test_reliable_publisher` | Mesaj teslim garantisi | Timeout, retry, dead letter |
| `test_scalability` | O(N²) regresyon | N=10,50,100 döngü süresi |
| `test_memory_leaks` | Bellek sızıntısı | 1000 döngü sonrası bellek kullanımı |

---

## 7.7 Faz 6: Deney Otomasyonu (1-2 Hafta)

**Amaç:** 90+ deneyi otomatik çalıştır, sonuçları yapılandırılmış kaydet.

### 7.7.1 Deney Çalıştırıcı

**Yeni dosya:** `experiments/experiment_runner.py`

### 7.7.2 Sonuç Toplayıcı

**Yeni dosya:** `experiments/data_collector.py`

### 7.7.3 Grafik Üretici

**Yeni dosya:** `experiments/plot_generator.py`

### 7.7.4 Rapor Üretici

**Yeni dosya:** `experiments/report_generator.py`

---

## 7.8 Faz 7: Ölçeklenebilirlik Optimizasyonları (3-4 Hafta)

### 7.8.1 Fleet Snapshot Pre-computation

**Neden:** O(N²) → O(N) dönüşümünün en büyük adımı. `fetch_mex_data()` döngü başında 1 kez çağrılır, sonucu tüm `manage_traffic()` çağrılarına parametre olarak geçirilir.

### 7.8.2 Asyncio Migration

**Neden:** Threading'in GIL sınırlamasını aşmak ve I/O-bound işleri (MQTT + DB) gerçekten paralel çalıştırmak.

### 7.8.3 Zone Partitioning

**Neden:** 500+ robot için tek Python sürecinin yapısal sınırlamasını aşmak.

---

## 7.9 Zaman Çizelgesi

```
Hafta 1-2:   Faz 1 — Acil düzeltmeler (SQL injection, crash bugları, QoS)
Hafta 3-5:   Faz 2 — İletişim katmanı yeniden tasarımı
Hafta 5-7:   Faz 3 — State management yeniden tasarımı
Hafta 7-10:  Faz 4 — Trafik yönetimi refactoring
Hafta 10-12: Faz 5 — Test altyapısı
Hafta 12-13: Faz 6 — Deney otomasyonu
Hafta 13-16: Faz 7 — Ölçeklenebilirlik optimizasyonları
```

**Toplam:** ~16 hafta (4 ay) — Tek geliştirici için agresif ama yapılabilir bir plan.

---

## 7.10 Risk Analizi

| Risk | Olasılık | Etki | Azaltma |
|------|----------|------|---------|
| Faz 2-3 mevcut testleri kırar | Yüksek | Orta | Her faz sonunda S1-S7 regresyon testi |
| Asyncio migration beklenenden uzun sürer | Orta | Yüksek | Asyncio'yu ayrı branch'te yap, thread-safe versiyon ana hat |
| Zone partitioning karmaşıklığı | Yüksek | Yüksek | Önce single-zone optimizasyonları tamamla |
| Test coverage hedefine ulaşılamaz | Orta | Düşük | Kritik yolları öncelikle test et (%50 coverage bile iyileşme) |
| Docker ortamında performans farklılıkları | Düşük | Orta | Bare-metal doğrulama deneyleri ekle |

---

## 7.11 Sonuç

Bu revizyon planı, OpenFMS'i **prototipten üretime taşımak** için gerekli adımları tanımlamaktadır. Anahtar kararlar:

1. **Acil güvenlik düzeltmeleri (Faz 1)** — SQL injection ve crash bugları derhal düzeltilmelidir
2. **İletişim katmanı (Faz 2)** — QoS 1 + ACK mekanizması, WiFi haberleşmenin temelini oluşturur
3. **State management (Faz 3)** — Immutable snapshot pattern, tüm race condition'ları ortadan kaldırır
4. **Trafik refactoring (Faz 4)** — 2734 satırlık monolitin parçalanması, bakımı ve test edilebilirliği sağlar
5. **Test + deney (Faz 5-6)** — Akademik yayın kalitesinde sonuç üretimin ön koşuludur
6. **Ölçekleme (Faz 7)** — O(N²) → O(N), threading → asyncio → zone partitioning

Her faz bağımsız olarak değer üretir — Faz 1 bile mevcut sistemi anlamlı şekilde güvenli hale getirir.
