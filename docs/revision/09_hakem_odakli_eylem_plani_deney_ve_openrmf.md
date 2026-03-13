# Hakem-Odaklı Eylem Planı: Deneyler ve OpenRMF Kıyaslama

Bu planın amacı, mimari yeniden yazım tartışmasını ikinci plana alıp hakemlerin istediği **doğrudan ampirik kanıtı** üretmektir.

## A) Önceliklendirme (yalnız hakem cevap etkisine göre)

1. **P1 (M1.1 + S2.1):** 20–50 robot ölçek deneyleri + computational overhead raporu.
2. **P1 (S2.2):** OpenRMF ile aynı topoloji/senaryo kıyası.
3. **P2 (M1.2):** 5–7 hedefli ablation/sensitivity.
4. **P2 (S2.3):** |R| > |V_W| failure mode deneyleri + formal bound.
5. **P3 (S2.4):** latency vs information age ayrımı (metin + metrik tabloları).

## B) Uygulanacak Deney Paketi

### B1) Ölçek Paketi (P1)
- Robot sayıları: 16, 24, 32, 40, 50
- Tekrar: 3 seed
- Süre: 180–240s
- Ana raporlar:
  - task_success_ratio
  - queue_pressure
  - detected_collisions
  - fleet_waiting_time_sec
  - overall_latency_sec
  - system_information_age_avg_sec / max_sec
  - run elapsed_sec (computational overhead proxy)

### B2) OpenRMF Kıyas Paketi (P1)
- Ortak topoloji: `config/config.yaml`
- Ortak robot seviyeleri: 4, 8, 16, 24
- Ortak seed ve süre
- Çıktı: ortak KPI şemasında iki JSONL + otomatik markdown karşılaştırma tablosu.

### B3) Ablation Paketi (P2)
- A0 baseline
- A1 fuzzy off / FIFO
- A2 reservation off
- S1-S4: α/β ve λ parametre profilleri (4 nokta)
- Toplam 7 koşu (hakem için yeterli, aşırı değil)

### B4) Hold-and-Wait Failure Paketi (P2)
- Önce config'ten |V_W| sayısı çıkarılır.
- Senaryo seti: R = |V_W|, |V_W|+1, |V_W|+2, |V_W|+5
- Beklenen çıktı: hangi noktada livelock/yoğunlaşma başlıyor?

## C) Bu repoda hazır araçlar (bu planı çalıştırmak için)

- Ölçek koşu sürücüsü: `scripts/experiments/run_reviewer_experiments.py`
- KPI çıkarımı: `scripts/experiments/collect_metrics.py`
- OpenFMS/OpenRMF kıyas manifesti: `scripts/experiments/prepare_framework_comparison.py`
- Hold-and-wait bound analizi: `scripts/experiments/analyze_waitpoint_capacity.py`
- Hedefli ablation manifesti: `scripts/experiments/generate_ablation_manifest.py`
- Kıyas tablo üretimi: `scripts/experiments/generate_framework_comparison_table.py`

## D) Çalıştırma Komutları (önerilen)

```bash
# 1) Ölçek planı (M1.1/S2.1)
python3 scripts/experiments/run_reviewer_experiments.py \
  --robot-counts 16,24,32,40,50 --repeats 3 --duration 240

# 2) OpenRMF kıyas manifesti (S2.2)
python3 scripts/experiments/prepare_framework_comparison.py \
  --robot-counts 4,8,16,24 --duration 180

# 3) Ablation manifesti (M1.2)
python3 scripts/experiments/generate_ablation_manifest.py \
  --robot-count 20 --duration 240

# 4) Hold-and-wait formal analiz (S2.3)
python3 scripts/experiments/analyze_waitpoint_capacity.py
```

## E) Makalede nasıl raporlanmalı?

- "Başarılı olduk" değil, **"hangi aralıkta ölçekleniyor, nerede kırılıyor"** dili.
- OpenRMF kıyasında aynı koşul eşitliği açıkça belirtilmeli (topoloji, süre, seed, KPI).
- S2.4 için aynı tabloda hem `overall_latency_sec` hem `system_information_age_avg_sec` verilerek yanıltıcı yorum riski kapatılmalı.

## Sonuç

Bu plan, hakemlerin eleştirisini doğrudan hedefleyen "deney-first" yaklaşımıdır. Mimari refactor önerileri korunabilir; ancak kabul kararını etkileyecek ana veri bu planın üreteceği karşılaştırmalı deney sonuçları olacaktır.
