# Tam Revizyon Planı (Nedenleriyle)

Bu plan, projeyi araştırma prototipinden üretim-aday mimariye taşımayı hedefler.

## Faz 0 — Güvenlik ve Doğruluk Bariyeri (2–3 hafta)

### İşler
- MQTT mTLS ve topic ACL politikaları
- Mesaj şeması sürümleme + strict validation
- Command idempotency anahtarı

### Neden?
Önce güvenlik/doğruluk sağlanmadan yapılan ölçekleme, hataları sadece büyütür.

## Faz 1 — Gözlemlenebilirlik ve SLO Çerçevesi (2 hafta)

### İşler
- OpenTelemetry izleri
- Prometheus metrikleri
- SLO: p99 command latency, task success ratio, reconnect recovery time

### Neden?
Ölçemediğiniz sistemi iyileştiremezsiniz; önce gözlemlenebilirlik.

## Faz 2 — Eşzamanlılık Yeniden Tasarımı (4–6 hafta)

### İşler
- Robot başına actor/event-loop modeli
- Shared mutable state kaldırma
- Atomic fleet snapshot ile planlama

### Neden?
Rastlantısal yarış koşullarını ortadan kaldırır, deterministik davranış sağlar.

## Faz 3 — Ölçeklenebilir Dağıtım Mimarisi (4 hafta)

### İşler
- Zone-partitioned manager'lar
- Mesajlaşma omurgası iyileştirmesi (gerekirse Kafka/Redpanda benzeri event log)
- DB tarafında read/write ayrımı, havuzlama, indeks iyileştirmesi

### Neden?
Tek süreç ve tek broker tasarımının fiziksel sınırları vardır.

## Faz 4 — Deneysel Doğrulama ve Yayınlanabilir Sonuçlar (3–4 hafta)

### İşler
- Parametrik benchmark pipeline
- İstatistiksel anlamlılık analizi
- Reproducible artifact üretimi

### Neden?
Bilimsel güvenilirlik ve mühendislik kararlarının kanıta dayalı olması.

## Başarı / Başarısızlık Karar Kriterleri

### Başarılı saymak için (örnek eşikler)
- Task success ratio ≥ %99 (N≤200, kayıp ≤%1)
- p99 command latency ≤ 500 ms
- Deadlock recovery p95 ≤ 5 s
- Broker kopması sonrası toparlanma ≤ 10 s

### Başarısızlık göstergeleri
- p99 gecikme kontrolsüz artış (ölçekle süperlineer)
- Collision/near-miss oranında artış
- Reconnect fırtınası ve kuyruk birikimi
- Deney tekrarlarında yüksek varyans (kararsız sistem)

## Planın Teslimat Çıktıları

- ADR dokümanları (mimari karar kayıtları)
- Test planları (fonksiyonel + kaos + performans)
- Otomatik benchmark raporları
- Operasyon runbook'ları

Bu çıktılar kod kadar önemlidir; çünkü sürdürülebilirlik ve devredilebilirlik bunlara bağlıdır.
