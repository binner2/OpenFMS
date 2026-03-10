# OpenFMS Akademik Analiz Raporu — Bölüm 1: Proje Genel Bakış

**Yazar:** Bağımsız Kod Denetim Raporu
**Tarih:** 2026-03-10
**Kapsam:** Mimari değerlendirme, tasarım felsefesi, ve sistematik eleştiri

---

## 1.1 OpenFMS Nedir?

OpenFMS (Open Source Fleet Management System), **VDA 5050 protokolü** üzerine inşa edilmiş, Python tabanlı bir **otonom mobil robot filo yönetim sistemi**dir. Endüstriyel ortamlarda (depo, fabrika, lojistik merkezi) birden fazla AGV'yi (Autonomous Guided Vehicle — Otonom Güdümlü Araç) merkezi olarak koordine etmeyi amaçlar.

### 1.1.1 Temel Bileşenler

| Bileşen | Dosya | Satır Sayısı | Sorumluluk |
|---------|-------|-------------|------------|
| Ana Döngü & MQTT Hub | `FmMain.py` | ~1134 | MQTT bağlantısı, ana olay döngüsü, CLI arayüzü |
| Görev Dağıtımı | `FmTaskHandler.py` | ~1411 | Bulanık mantık ile görev atama, yol planlama |
| Trafik Yönetimi | `FmTrafficHandler.py` | ~2734 | Çarpışma önleme, düğüm rezervasyonu, deadlock çözümü |
| Zamanlama | `FmScheduleHandler.py` | ~1155 | Robot yaşam döngüsü, boşta izleme, analitik |
| Robot Simülatörü | `FmRobotSimulator.py` | ~1328 | VDA 5050 uyumlu sanal robot |
| Senaryo Çalıştırıcı | `FmInterface.py` | ~196 | Otomatik test senaryoları |
| Graf Üretici | `FmSimGenerator.py` | ~1134 | Topoloji oluşturma |

### 1.1.2 Alt Modüller (Submodules)

| Modül | Dosya | Rol |
|-------|-------|-----|
| `StateSubscriber` | `submodules/state.py` | Robot durum mesajları (konum, batarya, hatalar) |
| `ConnectionSubscriber` | `submodules/connection.py` | Bağlantı durumu (ONLINE/OFFLINE) |
| `OrderPublisher` | `submodules/order.py` | Görev emirleri yayınlama |
| `InstantActionsPublisher` | `submodules/instant_actions.py` | Anlık komutlar (pick, drop, dock) |
| `FactsheetSubscriber` | `submodules/factsheet.py` | Robot fiziksel özellikleri |
| `VisualizationSubscriber` | `submodules/visualization.py` | Terminal UI ve loglama |

---

## 1.2 Mimari Genel Görünüm

```
┌──────────────────────────────────────────────────────────┐
│                    FmInterface                           │
│               (Dış görev dağıtıcı)                       │
└──────────────────┬───────────────────────────────────────┘
                   │
┌──────────────────▼───────────────────────────────────────┐
│                    FmMain                                 │
│        (MQTT Hub + Ana Döngü Thread'i)                   │
│  ┌─────────────────────────────────────────────────────┐ │
│  │ on_mqtt_message() → mesaj yönlendirme               │ │
│  │ main_loop() → 35sn aralıkla robot yönetimi          │ │
│  │ ThreadPoolExecutor (max 32 thread) → manage_robot()  │ │
│  └─────────────────────────────────────────────────────┘ │
└──────────────────┬───────────────────────────────────────┘
                   │
┌──────────────────▼───────────────────────────────────────┐
│              FmScheduleHandler                            │
│    manage_robot() → her robot için çağrılır              │
│  ┌────────────────────┬──────────────────────────────┐   │
│  │verify_robot_fitness │ FmTrafficHandler             │   │
│  │(bağlantı, durum,   │   .manage_traffic()          │   │
│  │ factsheet kontrol)  │     ├─ fetch_mex_data()     │   │
│  │                     │     └─ _handle_traffic()    │   │
│  └────────────────────┴──────────────────────────────┘   │
└──────────────────────────────────────────────────────────┘
                   │
┌──────────────────▼───────────────────────────────────────┐
│            Transport Katmanı                              │
│  ┌──────────┐  ┌──────────────┐  ┌──────────────────┐   │
│  │ Mosquitto │  │ PostgreSQL   │  │ In-Memory Cache  │   │
│  │ MQTT      │  │ (Kalıcılık)  │  │ (Hız)            │   │
│  │ Broker    │  │              │  │                   │   │
│  └──────────┘  └──────────────┘  └──────────────────┘   │
└──────────────────────────────────────────────────────────┘
```

---

## 1.3 Veri Akışı

### 1.3.1 MQTT Mesaj Akışı

```
ROBOT                          MQTT BROKER                    FLEET MANAGER
  │                                │                              │
  ├── state (her ~1sn) ──────────►│◄── StateSubscriber ─────────┤
  │   {batarya, konum, hatalar}    │    (cache'e yaz, DB'ye yaz)  │
  │                                │                              │
  ├── connection (her 15sn) ──────►│◄── ConnectionSubscriber ────┤
  │   {ONLINE/OFFLINE}             │                              │
  │                                │                              │
  ├── factsheet (başlangıçta) ────►│◄── FactsheetSubscriber ─────┤
  │   {maxPayload, boyutlar}       │                              │
  │                                │                              │
  │◄── order ─────────────────────┤◄── OrderPublisher ───────────┤
  │   {düğümler[], kenarlar[]}     │                              │
  │                                │                              │
  │◄── instantActions ────────────┤◄── InstantActionsPublisher ──┤
  │   {pick, drop, dock, charge}   │                              │
```

### 1.3.2 Karar Döngüsü (Her Robot İçin)

```
1. verify_robot_fitness()    → Robot çevrimiçi mi? Hatası var mı?
2. fetch_mex_data()          → Tüm filo durumunu oku (O(N) her robot için → O(N²))
3. manage_traffic()          → Bir sonraki düğüm müsait mi?
   ├─ Müsaitse → _handle_no_conflict_case() → düğümü serbest bırak
   ├─ Meşgulse → Öncelik karşılaştırması
   │   ├─ Yüksek öncelik → Diğer robotu waitpoint'e gönder
   │   ├─ Düşük öncelik → Kendini waitpoint'e gönder
   │   └─ Eşit → Bekleme süresi karşılaştırması
   └─ Son durak çakışması → Alternatif dock ara
4. order yayınla             → MQTT üzerinden yeni rota gönder
```

---

## 1.4 Neden Bu Proje Sorunlu?

### 1.4.1 Temel Tasarım Sorunları (Özet)

| # | Sorun | Şiddet | Durum |
|---|-------|--------|-------|
| 1 | **O(N²) trafik taraması** — `fetch_mex_data()` her robot için tüm filoyu tarar | Kritik | Devam ediyor |
| 2 | **`instant_actions` cache'siz** — Her döngüde her robot için DB sorgusu | Yüksek | Devam ediyor |
| 3 | **Paylaşılan değiştirilebilir durum** — `temp_robot_delay_time`, `collision_tracker`, `last_traffic_dict` thread-safe değil | Yüksek | Kısmen çözüldü |
| 4 | **QoS 0 kullanımı** — Mesaj kaybı garantisi yok | Orta | Tasarım kararı |
| 5 | **Tek nokta arıza** — Tek MQTT broker, tek PostgreSQL | Kritik | Devam ediyor |
| 6 | **Python GIL** — Gerçek CPU paralelliği yok | Yapısal | Dil sınırlaması |
| 7 | **NTP senkronizasyon eksikliği** — Gecikme ölçümleri güvenilir değil | Orta | Devam ediyor |
| 8 | **SQL injection riski** — String birleştirme ile SQL sorguları | Yüksek | Devam ediyor |
| 9 | **`cancel_task` random dock seçimi** — Robot yanlış dock'a gönderiliyor | Orta | Devam ediyor |
| 10 | **Bellek sınırsız büyümesi** — `state.cache`, `latency_data`, `analytics_data` asla temizlenmiyor | Yüksek | Devam ediyor |

### 1.4.2 Felsefik Eleştiri

Bu proje, **prototipten üretime geçiş sancısı** yaşayan tipik bir akademik/startup projesinin özelliklerini taşımaktadır:

1. **Monolitik mimari**: Tüm mantık tek bir Python sürecinde; ölçeklenme yalnızca "daha büyük makine" ile mümkün (dikey ölçekleme).

2. **Implicit state management**: Robotların durumu MQTT callback'lerde dict'lere yazılıyor, ama bu dict'lerin tutarlılığı hiçbir mekanizmayla garanti edilmiyor. Bir callback yarıda kalırsa veya iki callback aynı anda aynı robot için gelirse, veri tutarsızlığı kaçınılmazdır.

3. **Separation of concerns eksikliği**: `FmTrafficHandler` hem veri çekme (fetch_mex_data), hem karar verme (conflict resolution), hem iletişim (order publish) yapıyor. Bu 2734 satırlık dosya tek başına bir mimari sorun.

4. **Test edilebilirlik**: Mevcut testler (`conflict_test.py`) yalnızca entegrasyon düzeyinde; birim testleri yok. Bulanık mantık kararlarının doğruluğu test edilmiyor.

---

## 1.5 VDA 5050 Protokolü Bağlamında Değerlendirme

VDA 5050, Alman Otomobil Endüstrisi Birliği'nin AGV'ler için tanımladığı standart iletişim protokolüdür. OpenFMS'in VDA 5050 uyumu:

| Özellik | VDA 5050 Gereksinimi | OpenFMS Durumu |
|---------|---------------------|----------------|
| Sipariş yönetimi | `order` mesajı ile düğüm/kenar rotası | ✅ Uyumlu |
| Anlık eylemler | `instantActions` ile pick/drop/charge | ✅ Uyumlu |
| Durum raporlama | `state` mesajı ile konum/batarya/hata | ✅ Uyumlu |
| Bağlantı izleme | `connection` mesajı ile ONLINE/OFFLINE | ✅ Uyumlu |
| Factsheet | Robot fiziksel özellikler | ✅ Uyumlu |
| QoS gereksinimleri | QoS 1 önerisi (en az bir kez) | ⚠️ Kısmen — `state` QoS 0 |
| Sipariş monotonluğu | `orderUpdateId` monoton artan | ✅ Uyumlu |
| Hata işleme | FATAL/WARNING/INFO hata seviyeleri | ✅ Uyumlu |

**Kritik VDA 5050 sapması**: State mesajları QoS 0 ile alınıyor. VDA 5050 standartında QoS seviyesi spesifik olarak tanımlanmamıştır, ancak güvenilirlik gerektiren endüstriyel ortamlarda QoS 1 minimum beklentidir. QoS 0 ile bir state mesajının kaybolması, fleet manager'ın eski veriye dayanarak karar vermesine ve potansiyel çarpışmaya yol açabilir.

---

## 1.6 Teknoloji Yığını Değerlendirmesi

| Teknoloji | Kullanım | Uygunluk |
|-----------|----------|----------|
| **Python 3.9+** | Ana dil | ⚠️ GIL nedeniyle CPU-bound işlemler için uygunsuz; I/O-bound (MQTT, DB) için yeterli |
| **paho-mqtt** | MQTT istemcisi | ✅ Endüstri standardı; ancak async desteği sınırlı |
| **PostgreSQL 13** | Kalıcı depolama | ✅ Uygun; ancak bağlantı havuzu yönetimi yetersiz |
| **psycopg2** | DB adaptörü | ⚠️ Senkron; `asyncpg` tercih edilmeliydi |
| **scikit-fuzzy** | Bulanık mantık | ✅ Akademik uygunluk; ancak üretimde performans sorunu |
| **Docker Compose** | Orkestrasyon | ✅ Geliştirme için uygun; üretim için Kubernetes gerekir |
| **Mosquitto** | MQTT broker | ⚠️ Tek düğüm; üretim için EMQX/VerneMQ cluster gerekir |

---

## 1.7 Sonuç

OpenFMS, VDA 5050 protokolünü Python'da başarıyla implemente eden, çalışan bir prototiptir. Ancak:

1. **80-120 robot** ötesinde ölçeklenme yapısal olarak mümkün değildir.
2. WiFi üzerinden haberleşme katmanı, endüstriyel güvenilirlik gereksinimlerini karşılamamaktadır.
3. Eşzamanlılık modeli, Python GIL ve paylaşılan değiştirilebilir durum nedeniyle kırılgandır.
4. Deney altyapısı, akademik yayın kalitesinde sonuç üretmek için yetersizdir.

Bu sorunların her biri, sonraki bölümlerde derinlemesine analiz edilecektir.
