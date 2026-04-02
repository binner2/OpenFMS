#!/bin/bash
# ============================================================
# OpenFMS Full Audit — Tum Analizleri Sırayla Calistir
# ============================================================
# AMAC: Tum analiz script'lerini sirasiyla calistirarak
#       kapsamli bir denetim raporu uretir.
#
# KULLANIM:
#   ./scripts/10_full_audit.sh
#   ./scripts/10_full_audit.sh --skip-docker  (Docker gerektirmeyen testler)
#
# CIKTI:
#   results/full_audit_<timestamp>/
#     ├── 01_bugs.txt
#     ├── 08_qos.txt
#     ├── 09_race_conditions.txt
#     └── audit_summary.txt
#
# NE YAPAR:
#   1. Bug detector (statik analiz)
#   2. QoS karsilastirmasi
#   3. Race condition tespiti
#   4. (opsiyonel) Memory leak testi
#   5. (opsiyonel) Scalability benchmark
#   6. (opsiyonel) Conflict senaryolari
#   7. Tum sonuclari tek bir raporda birlestirir
# ============================================================

source "$(dirname "$0")/_common.sh"
ensure_dirs

SKIP_DOCKER=${1:---include-docker}
TS=$(timestamp)
AUDIT_DIR="$RESULTS_DIR/full_audit_${TS}"
mkdir -p "$AUDIT_DIR"

SUMMARY_FILE="$AUDIT_DIR/audit_summary.txt"

log_header "OpenFMS Full Audit"
log_info "Tarih: $(timestamp_iso)"
log_info "Cikti dizini: $AUDIT_DIR"

cat > "$SUMMARY_FILE" << HEADER_EOF
OpenFMS Full Audit Raporu
==========================
Tarih: $(timestamp_iso)
Mod:   $SKIP_DOCKER

ADIMLAR
-------
HEADER_EOF

# ── 1. Bug Detector (statik — Docker gerektirmez) ─────────
log_header "Adim 1/6: Bug Detector"
bash "$SCRIPT_DIR/01_bug_detector.sh" 2>&1 | tee "$AUDIT_DIR/01_bugs_output.txt"
LATEST_BUG=$(ls -t "$RESULTS_DIR"/bug_report_*.txt 2>/dev/null | head -1)
if [ -n "$LATEST_BUG" ]; then
    cp "$LATEST_BUG" "$AUDIT_DIR/01_bugs.txt"
    echo "  [OK] Bug detector tamamlandi." >> "$SUMMARY_FILE"
else
    echo "  [HATA] Bug detector sonuc uretmedi." >> "$SUMMARY_FILE"
fi

# ── 2. QoS Karsilastirmasi (statik — Docker gerektirmez) ──
log_header "Adim 2/6: QoS Karsilastirmasi"
bash "$SCRIPT_DIR/08_qos_comparison.sh" 2>&1 | tee "$AUDIT_DIR/02_qos_output.txt"
LATEST_QOS=$(ls -t "$RESULTS_DIR"/qos_comparison_*.txt 2>/dev/null | head -1)
if [ -n "$LATEST_QOS" ]; then
    cp "$LATEST_QOS" "$AUDIT_DIR/02_qos.txt"
    echo "  [OK] QoS karsilastirmasi tamamlandi." >> "$SUMMARY_FILE"
else
    echo "  [HATA] QoS karsilastirmasi sonuc uretmedi." >> "$SUMMARY_FILE"
fi

# ── 3. Race Condition Detector (statik) ───────────────────
log_header "Adim 3/6: Race Condition Detector"
bash "$SCRIPT_DIR/09_race_condition_detector.sh" 2>&1 | tee "$AUDIT_DIR/03_race_output.txt"
LATEST_RACE=$(ls -t "$RESULTS_DIR"/race_condition_report_*.txt 2>/dev/null | head -1)
if [ -n "$LATEST_RACE" ]; then
    cp "$LATEST_RACE" "$AUDIT_DIR/03_race_conditions.txt"
    echo "  [OK] Race condition detector tamamlandi." >> "$SUMMARY_FILE"
else
    echo "  [HATA] Race condition detector sonuc uretmedi." >> "$SUMMARY_FILE"
fi

# ── Docker gerektiren testler ──────────────────────────────
if [ "$SKIP_DOCKER" != "--skip-docker" ]; then

    # 4. Conflict Senaryolari
    log_header "Adim 4/6: Conflict Senaryolari"
    bash "$SCRIPT_DIR/05_conflict_scenarios.sh" 2>&1 | tee "$AUDIT_DIR/04_conflicts_output.txt"
    LATEST_CONFLICT=$(ls -t "$RESULTS_DIR"/conflict_test_*.txt 2>/dev/null | head -1)
    if [ -n "$LATEST_CONFLICT" ]; then
        cp "$LATEST_CONFLICT" "$AUDIT_DIR/04_conflicts.txt"
        echo "  [OK] Conflict senaryolari tamamlandi." >> "$SUMMARY_FILE"
    else
        echo "  [HATA] Conflict senaryolari sonuc uretmedi." >> "$SUMMARY_FILE"
    fi

    # 5. Memory Leak (kisa — 5 dakika)
    log_header "Adim 5/6: Memory Leak Testi (5dk)"
    bash "$SCRIPT_DIR/02_memory_leak_detector.sh" 5 5 2>&1 | tee "$AUDIT_DIR/05_memory_output.txt"
    LATEST_MEMORY=$(ls -t "$RESULTS_DIR"/memory_leak_*.txt 2>/dev/null | head -1)
    if [ -n "$LATEST_MEMORY" ]; then
        cp "$LATEST_MEMORY" "$AUDIT_DIR/05_memory.txt"
        echo "  [OK] Memory leak testi tamamlandi." >> "$SUMMARY_FILE"
    else
        echo "  [HATA] Memory leak testi sonuc uretmedi." >> "$SUMMARY_FILE"
    fi

    # 6. Scalability (hizli mod)
    log_header "Adim 6/6: Scalability Benchmark (quick)"
    bash "$SCRIPT_DIR/03_scalability_benchmark.sh" --quick 2>&1 | tee "$AUDIT_DIR/06_scalability_output.txt"
    LATEST_SCALE=$(ls -t "$RESULTS_DIR"/scalability_*.txt 2>/dev/null | head -1)
    if [ -n "$LATEST_SCALE" ]; then
        cp "$LATEST_SCALE" "$AUDIT_DIR/06_scalability.txt"
        echo "  [OK] Scalability benchmark tamamlandi." >> "$SUMMARY_FILE"
    else
        echo "  [HATA] Scalability benchmark sonuc uretmedi." >> "$SUMMARY_FILE"
    fi

else
    echo "  [ATLANDI] Docker testleri (--skip-docker)" >> "$SUMMARY_FILE"
    log_warn "Docker testleri atlanıyor (--skip-docker)"
fi

# ── Ozet ───────────────────────────────────────────────────
echo "" >> "$SUMMARY_FILE"
echo "DOSYALAR" >> "$SUMMARY_FILE"
echo "--------" >> "$SUMMARY_FILE"
ls -la "$AUDIT_DIR"/ >> "$SUMMARY_FILE"

log_header "Full Audit Tamamlandi"
log_info "Sonuclar: $AUDIT_DIR/"
log_info "Ozet:     $SUMMARY_FILE"
echo ""
echo "Dosyalar:"
ls -la "$AUDIT_DIR"/
