#!/bin/bash
# ============================================================
# OpenFMS Bug Detector — Statik Analiz
# ============================================================
# AMAC: analysis/02_BUG_ANALIZI raporundaki 9 kritik bug'u
#       otomatik olarak kod tabanında tarar ve raporlar.
#
# KULLANIM: ./scripts/01_bug_detector.sh
#
# CIKTI:   results/bug_report_<timestamp>.json
#          Terminal'de renkli ozet
#
# NE YAPAR:
#   BUG-01: SQL injection (string birlestirme ile SQL)
#   BUG-02: Tanimsiz degisken referanslari
#   BUG-03: Kapatilmayan cursor'lar
#   BUG-04: Race condition (korumasiz cache erisimi)
#   BUG-05: Sinirsiz bellek buyumesi (temizlenmeyen dict'ler)
#   BUG-06: Hata yutma (genis except bloklari)
#   BUG-07: DISTINCT ON SQL sorgu hatasi
#   BUG-08: Parametre uyumsuzlugu
#   BUG-09: Tanimsiz ctx referansi
#   BUG-10: finally bloklarinda tanimsiz degisken
#   SEC-01: Plaintext sifre
#   SEC-02: MQTT auth eksikligi
#   SEC-03: TLS eksikligi
# ============================================================

source "$(dirname "$0")/_common.sh"
ensure_dirs

log_header "OpenFMS Bug Detector — Statik Analiz"

REPORT_FILE="$RESULTS_DIR/bug_report_$(timestamp).txt"
BUG_COUNT=0
WARN_COUNT=0

check_bug() {
    local id="$1"
    local severity="$2"
    local description="$3"
    local pattern="$4"
    local glob_pattern="${5:-*.py}"

    local matches
    matches=$(grep -rn --include="$glob_pattern" -E "$pattern" "$PROJECT_ROOT/fleet_management" "$PROJECT_ROOT/submodules" 2>/dev/null || true)

    if [ -n "$matches" ]; then
        BUG_COUNT=$((BUG_COUNT + 1))
        echo -e "${RED}[BULUNDU]${NC} ${BOLD}$id${NC} ($severity): $description"
        echo "$matches" | head -5 | while IFS= read -r line; do
            echo "          $line"
        done
        local total=$(echo "$matches" | wc -l)
        if [ "$total" -gt 5 ]; then
            echo "          ... ve $((total - 5)) ek konum"
        fi
        echo ""
        # Rapora yaz
        echo "=== $id ($severity) ===" >> "$REPORT_FILE"
        echo "Aciklama: $description" >> "$REPORT_FILE"
        echo "Konumlar:" >> "$REPORT_FILE"
        echo "$matches" >> "$REPORT_FILE"
        echo "" >> "$REPORT_FILE"
    else
        log_success "$id: Temiz — $description"
    fi
}

check_warning() {
    local id="$1"
    local description="$2"
    local pattern="$3"
    local glob_pattern="${4:-*.py}"

    local matches
    matches=$(grep -rn --include="$glob_pattern" -E "$pattern" "$PROJECT_ROOT/fleet_management" "$PROJECT_ROOT/submodules" 2>/dev/null || true)

    if [ -n "$matches" ]; then
        WARN_COUNT=$((WARN_COUNT + 1))
        echo -e "${YELLOW}[UYARI]${NC} $id: $description ($(echo "$matches" | wc -l) konum)"
        echo "" >> "$REPORT_FILE"
        echo "--- $id (UYARI) ---" >> "$REPORT_FILE"
        echo "Aciklama: $description" >> "$REPORT_FILE"
        echo "$matches" >> "$REPORT_FILE"
    fi
}

# Rapor basliği
echo "OpenFMS Bug Detector Raporu" > "$REPORT_FILE"
echo "Tarih: $(timestamp_iso)" >> "$REPORT_FILE"
echo "========================================" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

# ── BUG-01: SQL Injection ──────────────────────────────────
log_step "1/13" "SQL Injection taranıyor..."
check_bug "BUG-01" "KRITIK" \
    "SQL injection — string birlestirme ile SQL sorgusu" \
    '(execute\(.*\+.*self\.table|execute\(f"|execute\(f'\'')'

# ── BUG-02: Tanimsiz degisken ──────────────────────────────
log_step "2/13" "Tanimsiz degisken riski taranıyor..."
check_bug "BUG-02" "YUKSEK" \
    "return satirinda ilk atama olmadan kullanilan degiskenler (fetch_data pattern)" \
    'return serial_number.*maps.*order_id'

# ── BUG-03: Kapatilmayan cursor ────────────────────────────
log_step "3/13" "Kapatilmayan cursor'lar taranıyor..."
# cursor() cagrisi yapan ama cursor.close() veya with blogu olmayan fonksiyonlar
CURSOR_OPENS=$(grep -rn --include="*.py" "\.cursor()" "$PROJECT_ROOT/submodules" 2>/dev/null | wc -l)
CURSOR_CLOSES=$(grep -rn --include="*.py" "cursor\.close\(\)\|with.*cursor" "$PROJECT_ROOT/submodules" 2>/dev/null | wc -l)
CURSOR_DIFF=$((CURSOR_OPENS - CURSOR_CLOSES))
if [ "$CURSOR_DIFF" -gt 2 ]; then
    BUG_COUNT=$((BUG_COUNT + 1))
    echo -e "${RED}[BULUNDU]${NC} ${BOLD}BUG-03${NC} (YUKSEK): Kapatilmayan cursor — $CURSOR_OPENS acilis, $CURSOR_CLOSES kapanis ($CURSOR_DIFF fark)"
    echo "" >> "$REPORT_FILE"
    echo "=== BUG-03 (YUKSEK) ===" >> "$REPORT_FILE"
    echo "cursor() acilis: $CURSOR_OPENS, cursor.close(): $CURSOR_CLOSES, Fark: $CURSOR_DIFF" >> "$REPORT_FILE"
else
    log_success "BUG-03: Cursor acma/kapama dengeli ($CURSOR_OPENS/$CURSOR_CLOSES)"
fi

# ── BUG-04: Race Condition ─────────────────────────────────
log_step "4/13" "Korumasiz cache erisimi taranıyor..."
check_bug "BUG-04" "KRITIK" \
    "Korumasiz cache erisimi — Lock olmadan dict iterasyonu" \
    'for.*in.*\.cache\.items\(\)|for.*in.*raw_cache\.items\(\)'

# ── BUG-05: Sinirsiz bellek buyumesi ───────────────────────
log_step "5/13" "Temizlenmeyen veri yapilari taranıyor..."
check_warning "BUG-05a" \
    "analytics_data dict — asla temizlenmiyor" \
    'self\.analytics_data\s*='

check_warning "BUG-05b" \
    "latency_data dict — asla temizlenmiyor" \
    'self\.latency_data\s*='

check_warning "BUG-05c" \
    "orders_issued dict — asla temizlenmiyor" \
    'self\.orders_issued\s*='

# ── BUG-06: Hata yutma ────────────────────────────────────
log_step "6/13" "Genis except bloklari taranıyor..."
BROAD_EXCEPT=$(grep -rn --include="*.py" "except Exception" "$PROJECT_ROOT/fleet_management" "$PROJECT_ROOT/submodules" 2>/dev/null | wc -l)
if [ "$BROAD_EXCEPT" -gt 10 ]; then
    WARN_COUNT=$((WARN_COUNT + 1))
    echo -e "${YELLOW}[UYARI]${NC} BUG-06: $BROAD_EXCEPT adet 'except Exception' blogu — cok genis hata yakalama"
    echo "" >> "$REPORT_FILE"
    echo "--- BUG-06 (UYARI) ---" >> "$REPORT_FILE"
    echo "Toplam 'except Exception' sayisi: $BROAD_EXCEPT" >> "$REPORT_FILE"
else
    log_success "BUG-06: except Exception sayisi kabul edilebilir ($BROAD_EXCEPT)"
fi

# ── BUG-07: DISTINCT ON sorgu hatasi ──────────────────────
log_step "7/13" "DISTINCT ON SQL sorgu hatasi taranıyor..."
check_bug "BUG-07" "ORTA" \
    "DISTINCT ON + ORDER BY uyumsuzlugu" \
    'DISTINCT ON.*serial_number.*ORDER BY timestamp'

# ── BUG-08: Parametre uyumsuzlugu ─────────────────────────
log_step "8/13" "last_mile_conflict_case parametre hatasi taranıyor..."
check_bug "BUG-08" "KRITIK" \
    "ctx keyword arguman olarak gecilmeden positional cagrı" \
    '_handle_last_mile_conflict_case\(.*checking_traffic_control,\s*ctx\)'

# ── BUG-09: Tanimsiz ctx ──────────────────────────────────
log_step "9/13" "check_available_last_mile_dock ctx hatasi taranıyor..."
check_bug "BUG-09" "KRITIK" \
    "check_available_last_mile_dock fonksiyonunda ctx parametresi yok ama icerde kullaniliyor" \
    'def check_available_last_mile_dock\(self.*\)'

# ── BUG-10: finally tanimsiz cursor ───────────────────────
log_step "10/13" "finally bloklarinda tanimsiz degisken taranıyor..."
check_warning "BUG-10" \
    "finally bloklarinda cursor.close() — cursor tanimsiz olabilir" \
    'finally:.*cursor\.close'

# ── SEC-01: Plaintext sifre ───────────────────────────────
log_step "11/13" "Plaintext sifre taranıyor..."
check_bug "SEC-01" "ORTA" \
    "Plaintext veritabani sifresi konfigurasyon dosyasinda" \
    'password:.*root|password:.*postgres' \
    "*.yaml"

# ── SEC-02: MQTT Auth ────────────────────────────────────
log_step "12/13" "MQTT kimlik dogrulama kontrolu..."
if ! grep -q "password_file\|allow_anonymous false" "$PROJECT_ROOT/config/mosquitto.conf" 2>/dev/null; then
    BUG_COUNT=$((BUG_COUNT + 1))
    echo -e "${RED}[BULUNDU]${NC} ${BOLD}SEC-02${NC} (YUKSEK): MQTT broker'da kimlik dogrulama yok"
    echo "=== SEC-02 (YUKSEK) ===" >> "$REPORT_FILE"
    echo "mosquitto.conf: allow_anonymous false veya password_file bulunamadi" >> "$REPORT_FILE"
else
    log_success "SEC-02: MQTT auth konfigürasyonu mevcut"
fi

# ── SEC-03: TLS ──────────────────────────────────────────
log_step "13/13" "TLS/SSL kontrolu..."
if ! grep -q "certfile\|cafile\|tls" "$PROJECT_ROOT/config/mosquitto.conf" 2>/dev/null; then
    BUG_COUNT=$((BUG_COUNT + 1))
    echo -e "${RED}[BULUNDU]${NC} ${BOLD}SEC-03${NC} (YUKSEK): MQTT iletisimi sifresiz (TLS yok)"
    echo "=== SEC-03 (YUKSEK) ===" >> "$REPORT_FILE"
    echo "mosquitto.conf: TLS konfigurasyonu bulunamadi" >> "$REPORT_FILE"
else
    log_success "SEC-03: TLS konfigürasyonu mevcut"
fi

# ── Rapor ozeti ────────────────────────────────────────────
echo "" >> "$REPORT_FILE"
echo "========================================" >> "$REPORT_FILE"
echo "OZET: $BUG_COUNT bug, $WARN_COUNT uyari" >> "$REPORT_FILE"

log_header "Sonuc"
if [ "$BUG_COUNT" -gt 0 ]; then
    echo -e "${RED}${BOLD}$BUG_COUNT kritik/yuksek bug bulundu.${NC}"
else
    echo -e "${GREEN}${BOLD}Kritik bug bulunamadi.${NC}"
fi
echo -e "${YELLOW}$WARN_COUNT uyari.${NC}"
echo ""
log_info "Detaylı rapor: $REPORT_FILE"
