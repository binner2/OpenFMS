#!/bin/bash
# ======================================================================
# Tum Hakem Deneyleri Orchestrator'u
# ======================================================================
# Bu script tum deney setlerini (A-E) sirasiyla calistirir.
# Oncelikle instrumentasyon yamalarini uygular, sonra deneyleri baslatsir.
#
# Kullanim:
#   ./run_all_experiments.sh                   # Tam calismak (141 deney, ~47 saat)
#   ./run_all_experiments.sh --quick           # Hizli mod (~3 saat)
#   ./run_all_experiments.sh --set A           # Sadece Set A
#   ./run_all_experiments.sh --set A,B         # Set A ve B
#   ./run_all_experiments.sh --dry-run         # Sadece plan goster
#   ./run_all_experiments.sh --patch-only      # Sadece yamalari uygula
#   ./run_all_experiments.sh --unpatch         # Yamalari geri al
# ======================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC}  $(date +%H:%M:%S) $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $(date +%H:%M:%S) $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date +%H:%M:%S) $*"; }

# ── Arguman Ayrıstirma ──────────────────────────────────────
MODE="full"
SETS_TO_RUN="A,B,C,D,E"
EXTRA_ARGS=""
DRY_RUN=false
PATCH_ONLY=false
UNPATCH=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --quick)      MODE="quick"; EXTRA_ARGS="--quick"; shift ;;
        --set)        SETS_TO_RUN="$2"; shift 2 ;;
        --dry-run)    DRY_RUN=true; EXTRA_ARGS="--dry-run"; shift ;;
        --patch-only) PATCH_ONLY=true; shift ;;
        --unpatch)    UNPATCH=true; shift ;;
        -h|--help)
            head -20 "$0" | tail -15
            exit 0 ;;
        *)
            echo "Bilinmeyen: $1"; exit 1 ;;
    esac
done

IFS=',' read -ra SETS <<< "$SETS_TO_RUN"

echo ""
echo -e "${BOLD}================================================================${NC}"
echo -e "${BOLD}  OPENFMS HAKEM DENEYLERI ORCHESTRATOR${NC}"
echo -e "${BOLD}================================================================${NC}"
echo ""
echo "  Mod          : $MODE"
echo "  Deney setleri: ${SETS[*]}"
echo "  Tarih        : $(date)"
echo ""

# ── Yama Yonetimi ────────────────────────────────────────────
apply_patches() {
    log_info "Instrumentasyon yamalari uygulaniyor..."

    python3 "$SCRIPT_DIR/patches/patch_fmmain_instrumentation.py" --apply
    if [ $? -eq 0 ]; then
        log_ok "FmMain.py instrumentasyon yamasi uygulandi."
    else
        log_error "FmMain.py yamasi basarisiz!"
        return 1
    fi

    python3 "$SCRIPT_DIR/patches/patch_state_information_age.py" --apply
    if [ $? -eq 0 ]; then
        log_ok "state.py information age yamasi uygulandi."
    else
        log_error "state.py yamasi basarisiz!"
        return 1
    fi
}

revert_patches() {
    log_info "Yamalar geri aliniyor..."
    python3 "$SCRIPT_DIR/patches/patch_fmmain_instrumentation.py" --revert || true
    python3 "$SCRIPT_DIR/patches/patch_state_information_age.py" --revert || true
    log_ok "Yamalar geri alindi."
}

if $UNPATCH; then
    revert_patches
    exit 0
fi

if ! $DRY_RUN; then
    apply_patches || exit 1
fi

if $PATCH_ONLY; then
    log_ok "Sadece yamalar uygulandi. Cikiliyor."
    exit 0
fi

# ── Sonuc Dizini ────────────────────────────────────────────
RESULTS_DIR="$PROJECT_DIR/results/reviewer_experiments"
mkdir -p "$RESULTS_DIR"

# ── Deney Setlerini Calistir ────────────────────────────────
TOTAL_START=$(date +%s)
FAILED_SETS=()

for SET in "${SETS[@]}"; do
    echo ""
    echo -e "${BOLD}================================================================${NC}"
    echo -e "${BOLD}  DENEY SETi $SET BASLATILIYOR${NC}"
    echo -e "${BOLD}================================================================${NC}"

    case $SET in
        A) SCRIPT="$SCRIPT_DIR/A_scaling_experiment.sh" ;;
        B) SCRIPT="$SCRIPT_DIR/B_ablation_experiment.sh" ;;
        C) SCRIPT="$SCRIPT_DIR/C_sensitivity_experiment.sh" ;;
        D) SCRIPT="$SCRIPT_DIR/D_saturation_experiment.sh" ;;
        E) SCRIPT="$SCRIPT_DIR/E_information_age_experiment.sh" ;;
        *)
            log_error "Bilinmeyen set: $SET"
            continue ;;
    esac

    if [ ! -f "$SCRIPT" ]; then
        log_error "Script bulunamadi: $SCRIPT"
        FAILED_SETS+=("$SET")
        continue
    fi

    SET_START=$(date +%s)
    bash "$SCRIPT" $EXTRA_ARGS
    SET_EXIT=$?
    SET_ELAPSED=$(( $(date +%s) - SET_START ))

    if [ $SET_EXIT -eq 0 ]; then
        log_ok "Set $SET tamamlandi ($(( SET_ELAPSED / 60 ))dk)"
    else
        log_error "Set $SET basarisiz (exit=$SET_EXIT)"
        FAILED_SETS+=("$SET")
    fi
done

# ── Grafik Uretimi ──────────────────────────────────────────
if ! $DRY_RUN; then
    echo ""
    log_info "Grafik uretimi baslatiliyor..."
    for SET in "${SETS[@]}"; do
        python3 "$SCRIPT_DIR/plot_results.py" --set "$SET" 2>/dev/null || \
            log_error "Set $SET grafik uretimi basarisiz."
    done
fi

# ── Yamalari Geri Al ────────────────────────────────────────
if ! $DRY_RUN; then
    echo ""
    revert_patches
fi

# ── Ozet Rapor ──────────────────────────────────────────────
TOTAL_ELAPSED=$(( $(date +%s) - TOTAL_START ))

echo ""
echo -e "${BOLD}================================================================${NC}"
echo -e "${BOLD}  TUM DENEYLER TAMAMLANDI${NC}"
echo -e "${BOLD}================================================================${NC}"
echo ""
echo "  Calisan setler  : ${SETS[*]}"
echo "  Basarisiz setler: ${FAILED_SETS[*]:-yok}"
echo "  Toplam sure     : $(( TOTAL_ELAPSED / 3600 ))s $(( (TOTAL_ELAPSED % 3600) / 60 ))dk"
echo "  Sonuclar        : $RESULTS_DIR/"
echo ""
echo "  Grafik olusturmak icin:"
echo "    python3 $SCRIPT_DIR/plot_results.py --all"
echo ""
echo -e "${BOLD}================================================================${NC}"
