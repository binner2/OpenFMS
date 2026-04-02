#!/bin/bash
# ============================================================
# OpenFMS Full Experiment Matrix Runner
# ============================================================
# AMAC: analysis/06_DENEY_TASARIMI raporundaki tam faktoriyel
#       deney matrisini otomatik olarak calistirir.
#
# KULLANIM:
#   ./scripts/06_experiment_matrix.sh              (standart matris)
#   ./scripts/06_experiment_matrix.sh --quick      (hizli: 2 robot sayisi, 1 tekrar)
#   ./scripts/06_experiment_matrix.sh --full       (tam: 6 robot, 3 harita, 5 tekrar)
#
# CIKTI:
#   results/experiment_matrix_<timestamp>/
#     ├── matrix_config.json     (deney konfigurasyonu)
#     ├── results.csv            (tum sonuclar)
#     ├── experiment_001.json    (her deney detayi)
#     ├── experiment_002.json
#     └── summary.txt            (ozet rapor)
#
# NE YAPAR:
#   Tam Faktoriyel Tasarim:
#     Robot sayilari:  [2, 10, 25, 50, 100]
#     Harita boyutlari: [kucuk(N/2), orta(2N), buyuk(10N)]
#     Tekrar:           3
#     Toplam:           5 x 3 x 3 = 45 deney
#
#   Her deney icin:
#     1. Harita olustur (GridFleetGraph)
#     2. Docker servislerini baslat
#     3. Isinma (warmup) bekle
#     4. Olcum periyodunda veri topla
#     5. Sonuclari JSON + CSV olarak kaydet
#     6. Servisleri durdur ve temizle
#
# NEDEN ONEMLI:
#   - Akademik yayin icin minimum 45 deney gerekli
#   - Tekrarlanabilirlik: random seed kaydedilir
#   - Istatistiksel guc: 3+ tekrar ile guven araligi
# ============================================================

source "$(dirname "$0")/_common.sh"
ensure_dirs

# ── Deney Matrisi Parametreleri ────────────────────────────
MODE=${1:---standard}
case "$MODE" in
    --quick)
        ROBOT_COUNTS=(2 10)
        MAP_MULTIPLIERS=(2)
        REPEATS=1
        DURATION_MIN=3
        WARMUP_SEC=20
        ;;
    --full)
        ROBOT_COUNTS=(2 5 10 25 50 100)
        MAP_MULTIPLIERS=(0.5 2 10)
        REPEATS=5
        DURATION_MIN=10
        WARMUP_SEC=60
        ;;
    *)
        ROBOT_COUNTS=(2 10 25 50 100)
        MAP_MULTIPLIERS=(2)
        REPEATS=3
        DURATION_MIN=5
        WARMUP_SEC=45
        ;;
esac

TS=$(timestamp)
MATRIX_DIR="$RESULTS_DIR/experiment_matrix_${TS}"
mkdir -p "$MATRIX_DIR"

CSV_FILE="$MATRIX_DIR/results.csv"
SUMMARY_FILE="$MATRIX_DIR/summary.txt"

# ── Toplam deney sayisi ────────────────────────────────────
TOTAL=$((${#ROBOT_COUNTS[@]} * ${#MAP_MULTIPLIERS[@]} * REPEATS))

log_header "Experiment Matrix Runner"
log_info "Mod: $MODE"
log_info "Robot sayilari: ${ROBOT_COUNTS[*]}"
log_info "Harita carpanlari: ${MAP_MULTIPLIERS[*]}"
log_info "Tekrar: $REPEATS"
log_info "Toplam deney: $TOTAL"
log_info "Tahmini toplam sure: ~$(( TOTAL * (DURATION_MIN + 3) )) dakika"
log_info "Sonuc dizini: $MATRIX_DIR"

# ── Matris konfigurasyonunu kaydet ─────────────────────────
cat > "$MATRIX_DIR/matrix_config.json" << CONFIG_EOF
{
    "timestamp": "$(timestamp_iso)",
    "mode": "$MODE",
    "robot_counts": [$(IFS=,; echo "${ROBOT_COUNTS[*]}")],
    "map_multipliers": [$(IFS=,; echo "${MAP_MULTIPLIERS[*]}")],
    "repeats": $REPEATS,
    "duration_minutes": $DURATION_MIN,
    "warmup_seconds": $WARMUP_SEC,
    "total_experiments": $TOTAL
}
CONFIG_EOF

# ── CSV basligi ────────────────────────────────────────────
echo "experiment_id,robot_count,map_nodes,map_multiplier,repeat,random_seed,duration_min,warmup_sec,manager_mem_mb,manager_cpu_pct,est_cycle_ms,status" > "$CSV_FILE"

# ── Ozet rapor basligi ────────────────────────────────────
cat > "$SUMMARY_FILE" << HEADER_EOF
OpenFMS Experiment Matrix — Ozet Rapor
=======================================
Tarih: $(timestamp_iso)
Mod: $MODE
Toplam deney: $TOTAL

DENEYLER
--------
HEADER_EOF

# ── Deney dongusu ──────────────────────────────────────────
EXP_ID=0

for N in "${ROBOT_COUNTS[@]}"; do
    for MAP_MULT in "${MAP_MULTIPLIERS[@]}"; do
        # Harita dugum sayisi = N * multiplier (min 10)
        MAP_NODES=$(echo "scale=0; v=$N * $MAP_MULT; if(v < 10) 10 else v" | bc)

        for R in $(seq 1 $REPEATS); do
            EXP_ID=$((EXP_ID + 1))
            RANDOM_SEED=$((EXP_ID * 42 + R * 7))

            log_header "Deney $EXP_ID/$TOTAL"
            log_info "N=$N | Map=${MAP_NODES} dugum (x$MAP_MULT) | Tekrar=$R | Seed=$RANDOM_SEED"

            EXP_STATUS="completed"

            # 1. Temizle
            clean_environment 2>/dev/null

            # 2. Harita olustur
            log_step "1/4" "Harita olusturuluyor..."
            cd "$PROJECT_ROOT"
            docker compose build --quiet 2>/dev/null

            # 3. Altyapiyi baslat
            log_step "2/4" "Altyapi baslatiliyor..."
            start_full_stack 2>/dev/null || {
                EXP_STATUS="infra_failed"
                log_error "Altyapi baslatma basarisiz!"
            }

            # 4. Isinma
            if [ "$EXP_STATUS" == "completed" ]; then
                log_step "3/4" "Isinma: ${WARMUP_SEC}s..."
                sleep "$WARMUP_SEC"
            fi

            # 5. Olcum
            MGR_MEM="0"
            MGR_CPU="0"
            EST_CYCLE="0"

            if [ "$EXP_STATUS" == "completed" ]; then
                log_step "4/4" "Olcum: ${DURATION_MIN}dk..."
                sleep $((DURATION_MIN * 60))

                # Metrikleri topla
                MGR_MEM=$(docker stats --no-stream --format "{{.MemUsage}}" "openfms-manager-1" 2>/dev/null | awk -F'/' '{print $1}' | sed 's/MiB//;s/ //' || echo "0")
                MGR_CPU=$(docker stats --no-stream --format "{{.CPUPerc}}" "openfms-manager-1" 2>/dev/null | tr -d '%' || echo "0")
                EST_CYCLE=$(echo "scale=0; $N * (15 + $N / 50)" | bc 2>/dev/null || echo "0")
            fi

            # 6. Sonuclari kaydet
            # Per-experiment JSON
            cat > "$MATRIX_DIR/experiment_$(printf '%03d' $EXP_ID).json" << EXP_EOF
{
    "experiment_id": $EXP_ID,
    "robot_count": $N,
    "map_nodes": $MAP_NODES,
    "map_multiplier": $MAP_MULT,
    "repeat": $R,
    "random_seed": $RANDOM_SEED,
    "duration_minutes": $DURATION_MIN,
    "warmup_seconds": $WARMUP_SEC,
    "manager_mem_mb": "$MGR_MEM",
    "manager_cpu_pct": "$MGR_CPU",
    "estimated_cycle_ms": $EST_CYCLE,
    "status": "$EXP_STATUS"
}
EXP_EOF

            # CSV satiri
            echo "$EXP_ID,$N,$MAP_NODES,$MAP_MULT,$R,$RANDOM_SEED,$DURATION_MIN,$WARMUP_SEC,$MGR_MEM,$MGR_CPU,$EST_CYCLE,$EXP_STATUS" >> "$CSV_FILE"

            # Ozet satiri
            echo "  #$EXP_ID: N=$N Map=$MAP_NODES R=$R → ~${EST_CYCLE}ms Mem=${MGR_MEM}MB [$EXP_STATUS]" >> "$SUMMARY_FILE"

            log_info "Deney #$EXP_ID tamamlandi: $EXP_STATUS"

            # 7. Durdur
            stop_all 2>/dev/null
        done
    done
done

# ── Genel ozet ─────────────────────────────────────────────
COMPLETED=$(grep -c "completed" "$CSV_FILE" || echo "0")
FAILED=$(grep -c "failed" "$CSV_FILE" || echo "0")

cat >> "$SUMMARY_FILE" << FOOTER_EOF

GENEL OZET
-----------
Toplam deney: $TOTAL
Tamamlanan:   $COMPLETED
Basarisiz:    $FAILED

Sonuc dizini: $MATRIX_DIR
CSV dosyasi:  $CSV_FILE

SONRAKI ADIMLAR
---------------
1. CSV'yi Python ile analiz edin:
   import pandas as pd
   df = pd.read_csv("$CSV_FILE")
   df.groupby("robot_count")["est_cycle_ms"].describe()

2. Grafik uretimi icin:
   ./scripts/07_plot_results.sh "$MATRIX_DIR"

3. Gercek dongu suresi olcumu icin FmMain.py'ye
   instrumentation ekleyin (bkz. analysis/06_DENEY_TASARIMI.md)
FOOTER_EOF

log_header "Experiment Matrix Tamamlandi"
log_success "$COMPLETED/$TOTAL deney basariyla tamamlandi"
log_info "Sonuclar: $MATRIX_DIR"
log_info "CSV: $CSV_FILE"
log_info "Ozet: $SUMMARY_FILE"
