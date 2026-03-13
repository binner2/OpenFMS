# OpenFMS Hakem Yorumları: Kod Aksiyonları, Deney Planı ve KPI Çerçevesi

Bu not, hakem maddelerini doğrudan **kod değişikliği + deney tasarımı + ölçüm çıktısı** formatına çevirir.

## 1) Yorumdan Eyleme Eşleme

## M1.1 / S2.1 — Ölçek yetersiz (8 robot)

### Kodda yapılacaklar
1. Deney arayüzünde robot sayısı parametreleştirilmeli.
2. Koşular süre kontrollü olmalı (otomatik sonlanma).
3. Çoklu tekrar (seed) koşusu otomatikleştirilmeli.

### Bu PR'daki karşılığı
- `FmInterface.py` içine `--num-robots`, `--duration`, `--analytics-interval`, `--task-spacing`, `--seed` parametreleri eklendi.
- Random task üretiminde robot listesi artık dinamik.
- Süre dolunca final analytics snapshot yazılıp güvenli kapanış yapılıyor.

## M1.2 — Ablation + sensitivity yok

### Kodda yapılacaklar
1. Deney sürücüsünde parametre matrisi desteği.
2. Her koşunun metadata'sı (seed, komut, süre, dönüş kodu) tutulmalı.

### Bu PR'daki karşılığı
- `scripts/experiments/run_reviewer_experiments.py` ile robot ölçek matrisi + repeat koşuları + run manifest kaydı eklendi.

> Not: Tam ablation (ör. reservation off / waitpoint off / scheduler varyantı) için algoritma tarafında feature toggle eklenmesi gerekir; bu PR altyapıyı hazırlıyor.

## S2.2 — Framework karşılaştırması yok

### Kodda yapılacaklar
1. Aynı topoloji/senaryo için dış framework runner'ı (ör. OpenRMF) normalize edilmiş API ile çağrılmalı.
2. Ortak KPI şeması (`kpi_results.jsonl`) kullanılmalı.

### Bu PR'daki karşılığı
- KPI parse/export altyapısı (`collect_metrics.py`) eklendi.
- OpenRMF adapter bu PR kapsamı dışında; ancak manifest ve KPI formatı onun eklenmesine uygun.

## S2.3 — Hold-and-wait failure mode analizi

### Kodda yapılacaklar
1. Buffer kapasitesi aşıldığında failure event sayacı eklenmeli.
2. Secondary congestion / starvation için olay metrikleri kaydedilmeli.

### Önerilen yeni metrikler
- `waitpoint_saturation_ratio`
- `reroute_failures`
- `starvation_events` (task age > eşik)

## S2.4 — Latency vs information age ayrımı

### Kodda yapılacaklar
1. Network latency ve information age ayrı hesaplanmalı.
2. State tazeliği için `AoI` metriği doğrudan loglanmalı.

### Önerilen formül
- `AoI(t) = t - t_last_state_timestamp`
- KPI: `aoi_p50`, `aoi_p95`, `aoi_p99`, `aoi_max`

## 2) Deney Tasarımı

## 2.1 Ölçek matrisi
- Robot sayısı: 8, 12, 16, 24, 32, 40, 50
- Tekrar: her seviyede en az 3
- Her koşu: 180 sn
- Çıktı: `artifacts/reviewer_runs/run_manifest.json` + run bazlı `*.kpi.jsonl`

## 2.2 Sensitivity başlangıç seti
- `task_spacing`: 1, 3, 5 sn
- `analytics_interval`: 10, 30, 60 sn
- Genişletilmiş fazda scheduler parametreleri (α, β, λ) için grid search önerilir.

## 3) KPI Seti (Bu PR ile çıkarılabilen)

1. **Task Success Ratio** = completed / (completed + cancelled)
2. **Queue Pressure** = unassigned / (active + unassigned)
3. **Detected Collisions**
4. **Fleet Waiting Time (sec)**
5. **Overall Latency (sec)**
6. **Robot Latency Spread** (min/max)

## 4) Sonuç Kaydetme Pratiği

Her run için önerilen artefaktlar:
- `run_manifest.json` (tekrar üretilebilirlik)
- `rc*_rep*.stdout.log`, `rc*_rep*.stderr.log` (hata ayıklama)
- `rc*_rep*.kpi.jsonl` (analiz girdisi)

Bu yapıyla reviewer taleplerindeki "descriptive" eleştirisi, daha sistematik ve tekrarlanabilir bir ölçüm hattına dönüştürülür.
