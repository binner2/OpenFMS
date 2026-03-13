# Ben Olsam Bu Paketi Nasıl Yazardım?

## 1) Mimari İlkeler

1. **Control-plane / Data-plane ayrımı**
   - Görev atama ve politika kararları (control-plane)
   - Telemetri akışı ve durum replikasyonu (data-plane)

2. **Event-driven çekirdek**
   - Robot olayları append-only log'a yazılır.
   - Planner, bu olaylardan deterministik state projection üretir.

3. **Idempotent komut protokolü**
   - Her komutta `command_id` + `version`.
   - Robot tarafı "exactly-once etki"yi idempotent uygulama ile sağlar.

4. **Failure-domain küçültme**
   - Zone-partitioned manager'lar (ör. her biri 100–200 robot).
   - Bölge arası sadece handoff protokolü.

## 2) Tekrarlamayacağım Hatalar

- Kritik topic'lerde QoS0 kullanımını varsayılan yapmazdım.
- Tek broker/tek DB'yi ölçeklenme hedefiyle çelişecek biçimde tek nokta bırakmazdım.
- Analitik ve karar döngüsünü aynı süreçte ağır görselleştirme ile karıştırmazdım.
- "Global mutable state" ile çoklu thread tasarımına güvenmezdim.
- Ölçülemeyen başarı kriteri ile proje yürütmezdim.

## 3) Programlayacağım Doğru Pratikler

- MQTT için mTLS + topic ACL + istemci sertifikası rotasyonu
- Komut/telemetri ayrık topic namespace + sürümleme politikası
- Robot state için TTL ve kompaksiyonlu cache
- Planner için deterministic replay testleri
- Property-based testler (çatışma çözüm tutarlılığı)
- Kaos mühendisliği: paket kaybı, gecikme, broker restart senaryoları

## 4) Hedef Referans Mimari (Öneri)

- **ingest-service**: MQTT tüketim + doğrulama + dedup
- **state-store**: event log + snapshot
- **planner-service**: görev atama + trafik çözümü
- **command-gateway**: robotlara komut yayını
- **analytics-service**: çevrimdışı metrik/rapor
- **experiment-orchestrator**: parametrik deney yönetimi

Bu ayrıştırma, hem hata izolasyonunu hem bağımsız ölçeklemeyi mümkün kılar.
