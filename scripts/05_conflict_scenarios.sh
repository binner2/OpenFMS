#!/bin/bash
# ============================================================
# OpenFMS Conflict Scenario Test Suite
# ============================================================
# AMAC: Mevcut conflict_test.py'deki 7 senaryoyu (S1-S7)
#       Docker ortaminda calistirip sonuclari raporlar.
#
# KULLANIM:
#   ./scripts/05_conflict_scenarios.sh          (tum senaryolar)
#   ./scripts/05_conflict_scenarios.sh S1       (tek senaryo)
#   ./scripts/05_conflict_scenarios.sh S1 S3 S5 (secili senaryolar)
#
# CIKTI:
#   results/conflict_test_<timestamp>.txt
#
# NE YAPAR:
#   S1: Mutex Group Conflict (2 robot, ayni hedefe gider)
#   S2a-S2d: No-Swap Conflicts (cesitli waitpoint senaryolari)
#   S3a-S3d: Swap Conflicts (deadlock senaryolari)
#   S4: Post-Resolution Continuation
#   S5: Mutex Group Enforcement
#   S6: Task Queueing Under Load
#   S7: Low Battery Auto-Charge Trigger
#
# NEDEN ONEMLI:
#   - BUG-08 (parametre uyumsuzlugu) last-mile conflict'te crash
#   - BUG-09 (ctx tanimsiz) check_available_last_mile_dock calismaz
#   - Trafik yonetimi mantik dogrulugunun temel testleri
# ============================================================

source "$(dirname "$0")/_common.sh"
ensure_dirs

# ── Parametreler ───────────────────────────────────────────
if [ $# -eq 0 ]; then
    SCENARIOS="all"
else
    SCENARIOS="$*"
fi

TS=$(timestamp)
REPORT_FILE="$RESULTS_DIR/conflict_test_${TS}.txt"

log_header "Conflict Scenario Test Suite"
log_info "Senaryolar: $SCENARIOS"

# ── Rapor basligi ──────────────────────────────────────────
cat > "$REPORT_FILE" << HEADER_EOF
OpenFMS Conflict Scenario Test Raporu
======================================
Tarih: $(timestamp_iso)
Senaryolar: $SCENARIOS

SONUCLAR
--------
HEADER_EOF

# ── Testleri calistir ─────────────────────────────────────
cd "$PROJECT_ROOT"

log_step "1/2" "Docker imajlari build ediliyor..."
docker compose build --quiet 2>/dev/null

log_step "2/2" "conflict_test.py calistiriliyor..."

# conflict_test.py'yi container icinde calistir
# Not: Bu test mock-based — MQTT/DB gerektirmez
TEST_OUTPUT=$(docker compose run --rm -T scenario python3 -m pytest \
    fleet_management/tests/conflict_test.py \
    -v --tb=short --no-header \
    2>&1) || true

echo "$TEST_OUTPUT"
echo "$TEST_OUTPUT" >> "$REPORT_FILE"

# ── Sonuc analizi ──────────────────────────────────────────
PASSED=$(echo "$TEST_OUTPUT" | grep -c "PASSED" || echo "0")
FAILED=$(echo "$TEST_OUTPUT" | grep -c "FAILED" || echo "0")
ERRORS=$(echo "$TEST_OUTPUT" | grep -c "ERROR" || echo "0")

echo "" >> "$REPORT_FILE"
echo "OZET" >> "$REPORT_FILE"
echo "-----" >> "$REPORT_FILE"
echo "Gecti: $PASSED" >> "$REPORT_FILE"
echo "Kaldi: $FAILED" >> "$REPORT_FILE"
echo "Hata:  $ERRORS" >> "$REPORT_FILE"

log_header "Sonuc"
if [ "$FAILED" -eq 0 ] && [ "$ERRORS" -eq 0 ]; then
    log_success "Tum senaryolar gecti ($PASSED/$PASSED)"
else
    log_error "$FAILED senaryo basarisiz, $ERRORS hata"
fi

log_info "Rapor: $REPORT_FILE"
