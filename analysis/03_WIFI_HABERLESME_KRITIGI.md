# OpenFMS Akademik Analiz Raporu — Bölüm 3: WiFi Üzerinden Haberleşme Kritiği

**Yazar:** Bağımsız Kod Denetim Raporu
**Tarih:** 2026-03-10
**Kapsam:** MQTT iletişim katmanının akademik eleştirisi ve ideal mimari önerisi

---

## 3.1 Mevcut İletişim Mimarisi

OpenFMS'in WiFi haberleşme katmanı şu yapıdadır:

```
┌─────────┐     WiFi (802.11)      ┌──────────────┐      TCP/IP        ┌──────────────┐
│ Robot 1  │◄────────────────────►│  Mosquitto   │◄──────────────────►│ Fleet Manager│
│ Robot 2  │◄────────────────────►│  MQTT Broker │◄──────────────────►│ (FmMain.py)  │
│ Robot N  │◄────────────────────►│  (Tek Düğüm) │                    │              │
└─────────┘                       └──────────────┘                    └──────────────┘
```

### 3.1.1 MQTT Konfigürasyonu

```yaml
# config/config.yaml
mqtt:
  broker_address: mqtt    # Docker service adı
  broker_port: '1883'     # Şifresiz TCP
  keep_alive: 15          # Saniye
```

```conf
# config/mosquitto.conf — Tam içeriği incelenmeli
# Varsayılan ayarlarla çalışıyor:
# - Kimlik doğrulama yok
# - TLS yok
# - Yetkilendirme yok
# - Mesaj kalıcılığı yok
```

### 3.1.2 Topic Yapısı

```
{fleetname}/{version}/{manufacturer}/{serialNumber}/{messageType}

Örnekler:
  kullar/v2/birfen/AGV-001/state          ← Robot → FM (her ~1sn)
  kullar/v2/birfen/AGV-001/connection      ← Robot → FM (her 15sn)
  kullar/v2/birfen/AGV-001/factsheet       ← Robot → FM (başlangıçta)
  kullar/v2/birfen/AGV-001/order           ← FM → Robot (gerektiğinde)
  kullar/v2/birfen/AGV-001/instantActions  ← FM → Robot (gerektiğinde)
```

### 3.1.3 QoS Seviyeleri

| Mesaj Tipi | Yön | QoS | Sorun |
|-----------|-----|-----|-------|
| `state` | Robot → FM | **0** (fire-and-forget) | Mesaj kaybı mümkün |
| `connection` | Robot → FM | **1** (en az bir kez) | Doğru |
| `order` | FM → Robot | **0** (fire-and-forget) | **KRİTİK** — Emir kaybı mümkün |
| `instantActions` | FM → Robot | **0** (fire-and-forget) | **KRİTİK** — Komut kaybı mümkün |
| `factsheet` | Robot → FM | **0** | Kabul edilebilir (nadiren değişir) |

---

## 3.2 Neden Kötü Kurgulanmış?

### 3.2.1 Problem 1: QoS 0 — Mesaj Kaybı Garantisizliği

**Akademik Bağlam:** MQTT QoS seviyeleri (0, 1, 2) mesaj teslimat garantilerini tanımlar. Endüstriyel otomasyon standartları (IEC 62443, ISA-95) minimum QoS 1 gerektirir.

**Mevcut Durum:** `state.py:168` ve `order.py:publish` — QoS 0 kullanılıyor.

**Senaryo Analizi:**

```
t=0: Robot AGV-001 C10 düğümünde. State: {lastNodeId: "C10", driving: false}
t=1: FM, AGV-001'e C11'e gitme emri verir (QoS 0)
     → WiFi paket kaybı! Emir hiç ulaşmaz.
t=2: FM, AGV-002'ye C11'e gitme emri verir (C11 müsait görünüyor)
t=3: AGV-001 hâlâ C10'da bekliyor (emir almadı)
     AGV-002 C11'e doğru hareket ediyor
t=4: FM tekrar kontrol eder — AGV-001'in emri var gibi görünüyor (DB'ye yazdı!)
     → İki robot çakışma yaşamaz ama AGV-001 sonsuza kadar bekler
```

**Daha kötü senaryo:**

```
t=0: AGV-001 C10'da, AGV-002 C11'de — head-on conflict
t=1: FM negotiation yapar:
     - AGV-001'e "W10'a git" emri (QoS 0) → KAYIP
     - AGV-002'ye "C10'a devam et" emri (QoS 0) → ulaştı
t=2: AGV-002, C10'a doğru hareket eder
     AGV-001 hâlâ C10'da (emir almadı)
t=3: FİZİKSEL ÇARPIŞMA — AGV-002, C10'a gelir, AGV-001 orada
```

**İstatistiksel Risk:** WiFi 2.4GHz ortamında tipik paket kaybı oranı %1-5 (endüstriyel ortamda girişim, metal yapılar, vb.). 100 robot × saniyede 1 mesaj = 100 mesaj/sn. %2 kayıp = 2 mesaj/sn = **120 kayıp mesaj/dakika**. Bunlardan biri kritik bir order veya instantAction ise, sistem arızalanır.

---

### 3.2.2 Problem 2: Tek Nokta Arıza (Single Point of Failure)

```
                    ┌──────────────┐
Tüm robotlar ──────►│  Mosquitto   │◄────── Fleet Manager
                    │  (TEK DÜĞÜM) │
                    └──────────────┘
                          │
                    Bu düşerse:
                    - Tüm robotlar emirsiz kalır
                    - Tüm durum bilgisi kaybolur
                    - Robotlar son bilinen konumda kalır
                    - İnsan müdahalesi gerekir
```

**Akademik Bağlam:** Dağıtık sistemlerde SPOF (Single Point of Failure) analizi, güvenilirlik mühendisliğinin temelidir. CAP teoremi bağlamında, mevcut sistem "Consistency" ve "Partition tolerance" arasında bir seçim yapmamıştır — çünkü partition durumunu hiç düşünmemiştir.

**Mosquitto'nun Sınırlamaları:**
- Native clustering desteği yok (Mosquitto v2.x)
- Bridge mode var ama gerçek HA (High Availability) değil
- Bellek tabanlı — restart'ta tüm session state kaybolur
- Maksimum bağlantı: ~100K (ancak throughput darboğazı daha önce gelir)

---

### 3.2.3 Problem 3: Mesaj Sıralama Garantisi Yok

MQTT QoS 0'da mesaj sıralama garantisi yoktur. QoS 1'de bile, TCP katmanında sıralama korunur, ancak broker failover durumunda garanti kaybolur.

**Senaryo:**
```
t=0: FM, AGV-001'e Order A gönderir (C10 → C11)
t=1: FM, AGV-001'e Order B gönderir (C11 → C12)  [güncelleme]
     → Ağ gecikmesi nedeniyle Order B, Order A'dan ÖNCE ulaşır
t=2: Robot Order B'yi alır — ama C11'de değil, C10'da!
     → VDA 5050 orderUpdateId monotonluğu bozulur
     → Robot Order B'yi reddeder (düşük updateId)
     → Order A gelir, uygulanır
     → Ama FM, Order B'nin uygulandığını varsayar
     → TUTARSIZLIK
```

**OpenFMS'te Mevcut Koruma:** `FmRobotSimulator.py`'de `orderUpdateId` monotonluk kontrolü var. Bu, sıra dışı gelen eski emirlerin reddedilmesini sağlar. **ANCAK** bu koruma yalnızca simülatörde var — gerçek robotlarda bu kontrol robotun firmware'ine bağlıdır ve OpenFMS bunu garanti edemez.

---

### 3.2.4 Problem 4: WiFi Spesifik Optimizasyon Yok

OpenFMS, WiFi ortamını **saf TCP/IP soket** olarak ele alıyor. Endüstriyel WiFi'nin gerçekleri:

| WiFi Gerçeği | OpenFMS'in Tutumu | Olması Gereken |
|-------------|-------------------|----------------|
| Roaming gecikmeleri (100-500ms) | Görmezden geliniyor | Roaming tespiti ve buffer mekanizması |
| 2.4GHz bant girişimi | Görmezden geliniyor | 5GHz/6GHz tercih, kanal planlama |
| Sinyal gücü değişkenliği | Görmezden geliniyor | RSSI tabanlı adaptif QoS |
| Bant genişliği sınırlaması | Görmezden geliniyor | Mesaj sıkıştırma, delta encoding |
| AP failover | Görmezden geliniyor | mDNS/DNS-SD ile broker keşfi |

**Roaming Senaryosu:**
```
t=0: AGV-001, AP-1'e bağlı (RSSI: -45dBm). State mesajları normal akıyor.
t=1: AGV-001, AP-1 kapsama alanından çıkıyor (RSSI: -75dBm)
t=2: Roaming başlıyor — 802.11r/k/v desteği yoksa 200-500ms kesinti
t=3: AP-2'ye bağlanıyor — TCP bağlantısı koptu
t=4: paho-mqtt reconnect deniyor — MQTT handshake + subscribe = 500ms-2s
t=5: Toplam kesinti: 700ms - 2.5s
     → Bu sürede FM, AGV-001'in state'ini almıyor
     → FM, AGV-001'i "3 dakikadan eski mesaj" olarak işaretleyip halt'a alabilir
```

---

### 3.2.5 Problem 5: Geri Bildirim Mekanizması Yok (Request-Reply Eksikliği)

MQTT publish-subscribe modelidir; request-reply pattern'ı native olarak desteklemez. OpenFMS'te:

```
FM: "AGV-001, C11'e git!" (order publish)
    ↓
    FM bunun ulaştığını NASIL BİLİR?
    ↓
    BİLMEZ. Sadece robot bir sonraki state mesajında
    yeni order'ı raporlayacağını UMAR.
```

**Mevcut workaround:** FM, order'ı DB'ye yazıyor ve robotun state'inde `orderId` değişikliğini bekliyor. Bu "eventual consistency" yaklaşımıdır, ancak:

1. Ne kadar bekleyecek? → `check_minute_passed(order_timestamp, 0.25)` = 15 saniye
2. 15 saniye içinde ulaşmazsa? → Robotun "geç kaldığı" varsayılır
3. Emir hiç ulaşmadıysa? → Robot sonsuza kadar eski emirde kalır

---

## 3.3 Nasıl Olmalıydı? — İdeal WiFi Haberleşme Mimarisi

### 3.3.1 Katmanlı İletişim Mimarisi

```
┌────────────────────────────────────────────────────────────────┐
│                    Uygulama Katmanı                            │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐ │
│  │ VDA 5050     │  │ Görev        │  │ Trafik               │ │
│  │ Mesaj Codec  │  │ Yönetimi     │  │ Yönetimi             │ │
│  └──────┬───────┘  └──────┬───────┘  └──────────┬───────────┘ │
│         │                 │                      │             │
│  ┌──────▼─────────────────▼──────────────────────▼───────────┐ │
│  │              Güvenilir Mesajlaşma Katmanı                 │ │
│  │  ┌─────────────┐ ┌──────────────┐ ┌────────────────────┐ │ │
│  │  │ Ack/Nack    │ │ Retry with   │ │ Sequence Number   │ │ │
│  │  │ Mekanizması │ │ Exp. Backoff │ │ Tracking          │ │ │
│  │  └─────────────┘ └──────────────┘ └────────────────────┘ │ │
│  └──────────────────────────┬────────────────────────────────┘ │
│                             │                                  │
│  ┌──────────────────────────▼────────────────────────────────┐ │
│  │              Taşıma Katmanı (Transport)                   │ │
│  │  ┌────────────┐ ┌──────────────┐ ┌──────────────────┐    │ │
│  │  │ MQTT       │ │ MQTT Cluster │ │ TLS 1.3          │    │ │
│  │  │ QoS 1/2    │ │ (EMQX/Verne)│ │ Şifreleme        │    │ │
│  │  └────────────┘ └──────────────┘ └──────────────────┘    │ │
│  └──────────────────────────┬────────────────────────────────┘ │
│                             │                                  │
│  ┌──────────────────────────▼────────────────────────────────┐ │
│  │              Ağ Adaptasyon Katmanı                        │ │
│  │  ┌────────────────┐ ┌──────────┐ ┌────────────────────┐  │ │
│  │  │ WiFi Roaming   │ │ RSSI     │ │ Bant Genişliği     │  │ │
│  │  │ Yönetimi       │ │ İzleme   │ │ Adaptasyonu        │  │ │
│  │  └────────────────┘ └──────────┘ └────────────────────┘  │ │
│  └───────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────┘
```

### 3.3.2 Güvenilir Emir Teslimi (Reliable Command Delivery)

```python
# İDEAL: Ack tabanlı emir teslimi
class ReliableOrderPublisher:
    def __init__(self, mqtt_client, timeout=5.0, max_retries=3):
        self.pending_acks = {}  # {order_id: {timestamp, retries, callback}}
        self._ack_lock = threading.Lock()

    async def publish_order(self, robot_id, order):
        """Onay alana kadar emri tekrar gönder."""
        order_id = order["orderId"]
        ack_future = asyncio.Future()

        with self._ack_lock:
            self.pending_acks[order_id] = {
                "timestamp": time.time(),
                "retries": 0,
                "future": ack_future,
                "order": order,
                "robot_id": robot_id
            }

        # QoS 1 ile yayınla
        self.mqtt_client.publish(
            f"{self.fleet}/{self.version}/{robot_id}/order",
            json.dumps(order),
            qos=1
        )

        try:
            # Robot'un ACK'ini bekle (state mesajında orderId değişikliği)
            result = await asyncio.wait_for(ack_future, timeout=self.timeout)
            return result
        except asyncio.TimeoutError:
            # Retry mekanizması
            return await self._retry_order(order_id)

    async def _retry_order(self, order_id):
        """Üstel geri çekilme ile yeniden deneme."""
        with self._ack_lock:
            pending = self.pending_acks.get(order_id)
            if not pending:
                return False

        if pending["retries"] >= self.max_retries:
            logger.critical(
                "Order %s teslim edilemedi — robot %s erişilemez!",
                order_id, pending["robot_id"]
            )
            # Robot'u halt moduna al
            return False

        backoff = 2 ** pending["retries"]  # 1, 2, 4 saniye
        await asyncio.sleep(backoff)

        pending["retries"] += 1
        self.mqtt_client.publish(
            f"{self.fleet}/{self.version}/{pending['robot_id']}/order",
            json.dumps(pending["order"]),
            qos=1
        )
        return await asyncio.wait_for(pending["future"], timeout=self.timeout)

    def on_state_received(self, robot_id, state_msg):
        """State mesajından ACK çıkar."""
        order_id = state_msg.get("orderId")
        with self._ack_lock:
            pending = self.pending_acks.pop(order_id, None)
        if pending:
            pending["future"].set_result(True)
```

### 3.3.3 MQTT Cluster Mimarisi

```
                    ┌───────────────────────────┐
                    │    Load Balancer (HAProxy) │
                    │    veya DNS Round Robin    │
                    └─────┬──────┬──────┬───────┘
                          │      │      │
                    ┌─────▼──┐ ┌─▼────┐ ┌▼──────┐
                    │ EMQX-1 │ │EMQX-2│ │EMQX-3 │
                    │ Node   │ │Node  │ │Node   │
                    └─────┬──┘ └─┬────┘ └┬──────┘
                          │      │       │
                    ┌─────▼──────▼───────▼──────┐
                    │   Shared Session Store     │
                    │   (Redis Cluster / RLOG)   │
                    └───────────────────────────┘
```

**Avantajlar:**
1. **Yatay ölçekleme**: Her node ~100K bağlantı → 3 node = 300K bağlantı
2. **Failover**: Bir node düşerse, robotlar otomatik olarak diğer node'lara bağlanır
3. **Bölgesel dağıtım**: Fabrikanın farklı bölümlerinde farklı node'lar
4. **Mesaj kalıcılığı**: Redis/RLOG ile session state korunur

### 3.3.4 Delta Encoding — Bant Genişliği Optimizasyonu

Mevcut durumda her state mesajı ~2-5 KB JSON. 100 robot × 1 mesaj/sn = 200-500 KB/sn = 1.6-4 Mbit/sn. Bu, endüstriyel WiFi'de sorun olmayabilir ama 1000 robotla 16-40 Mbit/sn olur.

```python
# İDEAL: Delta encoding ile bant genişliği optimizasyonu
class DeltaStateEncoder:
    def __init__(self):
        self.last_states = {}  # {robot_id: last_full_state}

    def encode(self, robot_id, current_state):
        """Yalnızca değişen alanları gönder."""
        last = self.last_states.get(robot_id)
        if last is None:
            self.last_states[robot_id] = current_state
            return {"_type": "full", **current_state}

        delta = {"_type": "delta", "serialNumber": robot_id}
        for key, value in current_state.items():
            if key == "serialNumber":
                continue
            if value != last.get(key):
                delta[key] = value

        self.last_states[robot_id] = current_state

        # Delta çok küçükse (sadece timestamp değişmiş), heartbeat gönder
        if len(delta) <= 3:  # _type + serialNumber + timestamp
            return {"_type": "heartbeat", "serialNumber": robot_id}

        return delta

    def decode(self, robot_id, message):
        """Delta mesajını tam state'e geri çevir."""
        msg_type = message.get("_type")
        if msg_type == "full":
            self.last_states[robot_id] = message
            return message
        elif msg_type == "heartbeat":
            return self.last_states.get(robot_id, message)
        else:  # delta
            full = dict(self.last_states.get(robot_id, {}))
            full.update(message)
            self.last_states[robot_id] = full
            return full
```

**Beklenen kazanım:** Tipik bir AGV, çoğu zaman yalnızca `agvPosition` ve `velocity` değiştirir. Delta encoding ile mesaj boyutu ~200 byte'a düşer → %90 bant genişliği tasarrufu.

### 3.3.5 WiFi Sağlık İzleme

```python
class WiFiHealthMonitor:
    """Robot tarafında çalışan WiFi sağlık izleme."""

    def __init__(self, mqtt_client, thresholds=None):
        self.thresholds = thresholds or {
            "rssi_warning": -70,     # dBm
            "rssi_critical": -80,    # dBm
            "latency_warning": 100,  # ms
            "latency_critical": 500, # ms
            "loss_rate_warning": 0.02,  # %2
            "loss_rate_critical": 0.05  # %5
        }
        self.latency_samples = collections.deque(maxlen=100)
        self.sent_count = 0
        self.ack_count = 0

    def publish_with_monitoring(self, topic, payload, qos=1):
        """Her yayın ile birlikte WiFi metriklerini topla."""
        send_time = time.monotonic()
        self.sent_count += 1

        # MQTT publish (QoS 1 → PUBACK bekleniyor)
        info = self.mqtt_client.publish(topic, payload, qos=qos)

        # PUBACK callback'inde gecikme hesapla
        def on_publish(mid):
            latency = (time.monotonic() - send_time) * 1000  # ms
            self.latency_samples.append(latency)
            self.ack_count += 1

        # Not: paho-mqtt'de on_publish callback mid bazlı
        self._pending_publishes[info.mid] = on_publish
        return info

    def get_health_report(self):
        """WiFi sağlık raporu üret."""
        avg_latency = statistics.mean(self.latency_samples) if self.latency_samples else 0
        p95_latency = sorted(self.latency_samples)[int(len(self.latency_samples)*0.95)] if len(self.latency_samples) > 20 else 0
        loss_rate = 1.0 - (self.ack_count / max(self.sent_count, 1))

        health = "GOOD"
        if avg_latency > self.thresholds["latency_warning"]:
            health = "DEGRADED"
        if avg_latency > self.thresholds["latency_critical"]:
            health = "CRITICAL"
        if loss_rate > self.thresholds["loss_rate_critical"]:
            health = "CRITICAL"

        return {
            "health": health,
            "avg_latency_ms": round(avg_latency, 2),
            "p95_latency_ms": round(p95_latency, 2),
            "loss_rate": round(loss_rate, 4),
            "samples": len(self.latency_samples)
        }
```

---

## 3.4 Star (Yıldız) vs Mesh Topoloji Tartışması

### 3.4.1 Mevcut: Star Topoloji (Hub-and-Spoke)

```
        Robot-1 ──┐
        Robot-2 ──┤
        Robot-3 ──┼──► MQTT Broker ◄──── Fleet Manager
        Robot-4 ──┤
        Robot-N ──┘
```

**Avantajlar:**
- Basit implementasyon
- Merkezi kontrol
- Mesaj sıralama garantisi (tek broker)

**Dezavantajlar:**
- SPOF (broker düşerse her şey durur)
- Bant genişliği darboğazı (tüm trafik tek noktadan geçer)
- Gecikme artar (robot-robot iletişimi broker üzerinden)

### 3.4.2 Alternatif: Mesh Topoloji (Robot-Robot Direkt İletişim)

```
        Robot-1 ◄───► Robot-2
           ▲  ╲          ▲
           │    ╲         │
           ▼      ╲       ▼
        Robot-3 ◄──╲─► Robot-4
                     ╲
                      ╲──► Fleet Manager
```

**Akademik Tartışma:**

Mesh topolojisi, robotlar arasında **doğrudan güvenlik mesajlaşması** için cazip görünür:

1. **Acil duruş (E-Stop)**: Robot-1, Robot-2'ye yaklaşıyorsa, broker üzerinden değil doğrudan "dur" diyebilir. Gecikme: 1-5ms (direkt) vs 10-50ms (broker üzerinden).

2. **Kooperatif navigasyon**: İki robot aynı koridorda karşılaşırsa, merkezi planlama yerine local negotiation yapabilir.

**ANCAK mesh topolojisi OpenFMS için UYGUN DEĞİLDİR:**

1. **VDA 5050 uyumsuzluğu**: VDA 5050, merkezi master control otorite varsayar. Robotlar arası direkt iletişim standart kapsamında değildir.

2. **Karar tutarlılığı**: Merkezi olmayan karar verme, **distributed consensus** problemini doğurur. Bizantin hata toleransı (BFT) gerekir — bu, AGV'ler için aşırı karmaşıktır.

3. **O(N²) bağlantı**: N robot, N(N-1)/2 direkt bağlantı gerektirir. 100 robot = 4,950 bağlantı. Bu, WiFi ortamında kanal doygunluğuna yol açar.

4. **WiFi Direct/P2P sınırlamaları**: 802.11p veya WiFi Direct, endüstriyel ortamlarda güvenilir değildir. AP üzerinden iletişim her zaman daha güvenilirdir.

### 3.4.3 Önerilen: Hibrit Topoloji

```
┌─────────────────────────────────────────────────────┐
│                 Bölge A (Zone A)                    │
│  Robot-1 ◄──► Local MQTT Broker A ◄──► Zone FM A  │
│  Robot-2 ◄──►                                      │
│  Robot-3 ◄──►                                      │
└─────────────────────┬───────────────────────────────┘
                      │ Cross-zone coordination
┌─────────────────────▼───────────────────────────────┐
│              Global Koordinatör                      │
│         (Redis Streams / Kafka)                      │
└─────────────────────┬───────────────────────────────┘
                      │
┌─────────────────────▼───────────────────────────────┐
│                 Bölge B (Zone B)                    │
│  Robot-4 ◄──► Local MQTT Broker B ◄──► Zone FM B  │
│  Robot-5 ◄──►                                      │
│  Robot-6 ◄──►                                      │
└─────────────────────────────────────────────────────┘
```

**Avantajlar:**
1. Her bölge bağımsız ölçeklenir (100-200 robot/bölge)
2. Broker arızası yalnızca bir bölgeyi etkiler
3. Bölge içi gecikme düşük (lokal broker)
4. Cross-zone traffic, global koordinatör üzerinden yönetilir

---

## 3.5 Sonuç

OpenFMS'in WiFi haberleşme katmanı, **araştırma prototipi** seviyesindedir. Endüstriyel kullanım için:

1. **QoS 1 minimum** — Tüm kritik mesajlar (order, instantActions) QoS 1 ile gönderilmelidir.
2. **MQTT Cluster** — Tek Mosquitto yerine EMQX/VerneMQ cluster kullanılmalıdır.
3. **TLS 1.3** — Tüm iletişim şifrelenmelidir.
4. **ACK mekanizması** — Order teslim onayı uygulama katmanında garanti edilmelidir.
5. **Delta encoding** — Bant genişliği %90 azaltılabilir.
6. **WiFi sağlık izleme** — Roaming, gecikme ve paket kaybı sürekli izlenmelidir.
7. **Bölge tabanlı mimari** — 1000+ robot için zorunludur.

Mevcut implementasyonun en tehlikeli sorunu: **FM bir emrin robota ulaşıp ulaşmadığını bilmeden, emrin uygulandığını varsaymasıdır.** Bu, endüstriyel ortamda kabul edilemez bir güvenlik açığıdır.
