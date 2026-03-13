# Hakem Yorumları × PR İçerikleri: Derin Cross-Reference Sentezi

Bu doküman, hakemlerin istediği şey ile PR'larda üretilenlerin nerede örtüştüğünü/ayrıştığını sistematikleştirir.

## 1) Ana Tez

Hakemler esasen "mevcut sistemi daha geniş ve disiplinli deneyle kanıtlayın" diyor.
PR tarafı ise çoğunlukla "mimariyi baştan tasarlayalım" ekseninde ilerliyor.

Bu nedenle revizyon stratejisi iki katmanlı olmalı:
1. **Kısa vadede**: mevcut kod tabanında ölçek/ablation/comparison deneylerini tamamla.
2. **Orta vadede**: mimari iyileştirme önerilerini roadmap olarak sakla (kanıt yerine geçmesin).

## 2) Madde Bazlı Uyum Durumu

### M1.1 + S2.1 (ölçek 20–50 robot)
- Durum: **Kısmi karşılandı**.
- Yeni katkı: `FmInterface.py` parametreleri + `run_reviewer_experiments.py` ile 20–50 bandı için tekrar üretilebilir koşular hazırlanabiliyor.

### S2.2 (OpenRMF ile doğrudan kıyas)
- Durum: **Karşılanmadı → Bu PR'da köprü kuruldu**.
- Yeni katkı: `prepare_framework_comparison.py` ile aynı KPI şemasını kullanan normalized manifest üretiliyor.
- Açık iş: OpenRMF runner adaptörü projeye bağlanmalı.

### M1.2 (ablation/sensitivity)
- Durum: **Altyapı hazır, tam değil**.
- Yeni katkı: matrix runner var; ancak algoritma toggles (fuzzy off, reservation off vb.) için ek bayraklar gerektiği açıkça belirtilmeli.

### S2.3 (hold-and-wait failure mode)
- Durum: **Yetersizdi → Bu PR'da formal başlangıç eklendi**.
- Yeni katkı: `analyze_waitpoint_capacity.py` ile |V_W| temelli kapasite sınırı ve |R|>|V_W| stres senaryoları dosyalanıyor.

### S2.4 (network latency vs information age)
- Durum: **Önceden karışıktı → Bu PR'da ayrım kodlandı**.
- Yeni katkı:
  - `StateSubscriber` içine information age (AoI proxy) hesapları eklendi.
  - `fm_analytics` artık latency yanında information age de logluyor.
  - `collect_metrics.py` bu KPI'ları parse ediyor.

## 3) Makale Revizyonunda Nasıl Konumlandırılmalı?

- "Sistemi yeniden yazdık" yerine: "Mevcut baseline için ölçek davranışı ve kırılma bölgelerini ölçtük" denmeli.
- 20–50 robot aralığı temel hedef; daha yüksek robot sayısı "degradation characterization" olarak raporlanmalı.
- OpenRMF kıyası için aynı topoloji + aynı seed + aynı KPI şeması zorunlu tutulmalı.

## 4) En Kritik KPI Seti (Hakem Odaklı)

1. task_success_ratio
2. queue_pressure
3. detected_collisions
4. fleet_waiting_time_sec
5. overall_latency_sec (network taşıma/gecikme proxy)
6. system_information_age_avg_sec
7. system_information_age_max_sec

Bu ikili (5 + 6/7), S2.4'te istenen "latency vs freshness" ayrımını doğrudan görünür kılar.

## 5) Sonuç

PR'lar artık sadece mimari eleştiri üretmiyor; hakemlerin somut deney taleplerine uygulanabilir bir deney hattı da sunuyor.
Ancak kabul için kritik blokaj hâlâ S2.2 (OpenRMF doğrudan karşılaştırma) deneyinin gerçek çalıştırılmasıdır.
