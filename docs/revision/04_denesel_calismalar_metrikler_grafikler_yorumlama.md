# Ölçeklenebilir Deneyler Nasıl Yapılır? Sonuçlar Nasıl Kaydedilir, Hangi Metrikler/Grafikler Gerekli?

## 1) Deney Tasarım Felsefesi

Tek koşu sonuçlarına güvenilmez. Her senaryo için:
- En az 20 tekrar (farklı random seed)
- Isınma (warm-up) ve ölçüm penceresi ayrımı
- Güven aralığı (95% CI) raporlama

## 2) Deney Matrisleri (Önerilen)

### A. Robot sayısı ölçekleme
- N = 10, 25, 50, 100, 200, 400, 800

### B. Ağ bozulması
- Paket kaybı: %0, %1, %3, %5
- RTT jitter: 5ms, 20ms, 50ms, 100ms
- Kısa kopma: 1s, 5s, 15s

### C. Görev yükü
- Düşük/orta/yüksek görev geliş oranı (Poisson λ)
- Patlamalı yük (burst) profili

## 3) Sonuçları Nasıl Kaydederiz?

Öneri: Her koşu için tek bir deney dizini:
- `run_metadata.json` (seed, parametreler, commit hash)
- `events.parquet` (zaman damgalı ham olaylar)
- `kpis.json` (hesaplanmış metrikler)
- `plots/*.png` (grafikler)

Ek olarak "tekrar üretilebilirlik" için:
- kullanılan konteyner imaj digest'i
- config snapshot
- çalışma zamanı donanım bilgisi

## 4) Gerekli Performans Metrikleri

### Çekirdek metrikler
1. Task success ratio
2. End-to-end task latency (p50/p95/p99)
3. Command apply latency (FM→robot)
4. State staleness (güncellik gecikmesi)
5. Collision/near-miss rate
6. Deadlock recovery time
7. Throughput (tasks/min)
8. Fairness (Jain index)

### Sistem metrikleri
1. CPU, bellek, GC duraklama süresi
2. DB bağlantı havuzu doyumu
3. MQTT topic lag / drop / duplicate
4. Reconnect sayısı ve ortalama toparlanma süresi

## 5) Hangi Grafikler Çizilmeli?

Mevcut tarz bar grafikler başlangıç için faydalı; fakat tek başına yetersizdir.

Mutlaka eklenmesi önerilenler:
- **CDF grafiği** (latency dağılım kuyruğu için)
- **Heatmap** (robot sayısı × ağ kaybı → başarı oranı)
- **Violin/box plot** (tekrarlar arası dağılım)
- **Timeline trace** (olay korelasyonu: task dispatch, ack, complete)
- **Queue length time-series** (backpressure analizi)

## 6) Sonuçlar Nasıl Yorumlanır?

Yorum, yalnız ortalamaya göre yapılmaz. En azından:
- Kuyruk metrikleri (p95/p99) hedef sınır altında mı?
- Başarı oranı ağ bozulmasında nasıl düşüyor?
- Ölçek büyürken bozulma lineer mi yoksa faz geçişi var mı?

## 7) Kaç Robotla Test Etmeliyim? Ortam Nasıl Olmalı?

### Minimum bilimsel set
- Fonksiyonel doğrulama: 5–20 robot
- Darboğaz keşfi: 50–200 robot
- Ölçek sınırı ve kırılma: 400+ robot

### Ortam
- Gerçekçi ağ emülasyonu (`tc/netem`)
- İzole deney ağı (tekrarlanabilirlik)
- Sabit CPU limitleri (karşılaştırılabilirlik)

## 8) Artırma Stratejisi Yeterli mi?

Sadece robot sayısını artırmak yeterli değildir. Eşzamanlı olarak:
- ağ bozulması,
- görev geliş oranı,
- harita/topoloji karmaşıklığı
artırılmalıdır.

Aksi halde "N arttı ama kolay senaryo" yanılgısı oluşur.
