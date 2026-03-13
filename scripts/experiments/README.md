# Reviewer-Oriented Experiment Scripts

Bu klasör, makale hakem yorumlarına yanıt için tekrarlanabilir deney koşuları üretmek amacıyla hazırlanmıştır.

## 1) Ölçekleme Deneyi Matrisi (M1.1, S2.1)

```bash
python3 scripts/experiments/run_reviewer_experiments.py \
  --robot-counts 8,12,16,24,32,40,50 \
  --repeats 3 \
  --duration 180 \
  --analytics-interval 30 \
  --task-spacing 3
```

## 2) Sadece Plan/Manifest Üretmek (dry-run)

```bash
python3 scripts/experiments/run_reviewer_experiments.py --skip-exec
```

## 3) KPI Çıkarma

Son snapshot dosyasından KPI almak için:

```bash
python3 scripts/experiments/collect_metrics.py --latest-only
```

Tüm snapshot dosyalarını topluca parse etmek için:

```bash
python3 scripts/experiments/collect_metrics.py --output artifacts/metrics/all_kpis.jsonl
```

## 4) Kaydedilen Ana KPI Alanları

- `completed_orders`, `cancelled_orders`
- `task_success_ratio`
- `active_orders`, `unassigned_orders`, `queue_pressure`
- `detected_collisions`
- `fleet_waiting_time_sec`
- `overall_latency_sec`
- `system_information_age_avg_sec`, `system_information_age_max_sec`
- `max_robot_latency_sec`, `min_robot_latency_sec`

Bu KPI'lar, reviewer yorumlarındaki ölçeklenme ve metrik netliği taleplerini karşılamak için başlangıç seti olarak düşünülmüştür.

## 5) Hold-and-Wait Kapasite Analizi (S2.3)

```bash
python3 scripts/experiments/analyze_waitpoint_capacity.py \
  --config config/config.yaml \
  --output artifacts/metrics/waitpoint_capacity.json
```

## 6) OpenFMS vs OpenRMF Karşılaştırma Manifesti (S2.2)

```bash
python3 scripts/experiments/prepare_framework_comparison.py \
  --robot-counts 4,8,16,24 \
  --duration 180 \
  --output artifacts/reviewer_runs/framework_manifest.json
```

## 7) Hedefli Ablation Manifesti (M1.2)

```bash
python3 scripts/experiments/generate_ablation_manifest.py \
  --robot-count 20 \
  --duration 240 \
  --output artifacts/reviewer_runs/ablation_manifest.json
```

## 8) OpenFMS vs OpenRMF Sonuç Tablosu Üretimi

```bash
python3 scripts/experiments/generate_framework_comparison_table.py \
  --openfms artifacts/reviewer_runs/openfms_kpi.jsonl \
  --openrmf artifacts/reviewer_runs/openrmf_kpi.jsonl \
  --output artifacts/reviewer_runs/openfms_openrmf_comparison.md
```
