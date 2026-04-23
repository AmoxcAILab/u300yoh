#!/usr/bin/env bash
# infrastructure/slurm/job_clean_modern.sh
# ──────────────────────────────────────────────────────
# Job Slurm GPU: modernización del texto histórico limpio
# con el modelo spanish_clean_modern.
#
# Prerequisito por htr_id: htr_cleaning_completed registrado.
#
# Para cada htr_id en el batch:
#   1. Ejecuta spanish_clean_modern sobre el hist_clean existente
#   2. Registra historical_clean_available + clean_modern_available
#      + descriptive_analysis_computed
#
# Argumentos posicionales:
#   $1  BATCH_FILE  — ruta a archivo con una htr_id por línea
#
# Uso:
#   sbatch job_clean_modern.sh batch_htr.txt
#
#SBATCH --job-name=htr_clean_modern
#SBATCH --output=slurm-logs/htr_clean_modern_%j.out
#SBATCH --error=slurm-logs/htr_clean_modern_%j.err
#SBATCH --partition=gpu
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=12:00:00

set -euo pipefail

# ── Argumentos ────────────────────────────────────────────────────────
BATCH_FILE="${1:-}"

if [ -z "$BATCH_FILE" ]; then
    echo "✗ Falta BATCH_FILE como primer argumento."
    echo "  Uso: sbatch job_clean_modern.sh <batch_file>"
    exit 1
fi

if [ ! -f "$BATCH_FILE" ]; then
    echo "✗ Archivo batch no encontrado: $BATCH_FILE"
    exit 1
fi

# ── Entorno ───────────────────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════"
echo "  HTR Pipeline — Modernización (spanish_clean_modern)"
echo "═══════════════════════════════════════════════════════"
echo "  Job ID    : ${SLURM_JOB_ID:-local}"
echo "  Nodo      : ${SLURMD_NODENAME:-$(hostname)}"
echo "  Batch     : $BATCH_FILE"
echo "  Fecha     : $(date '+%Y-%m-%d %H:%M:%S')"
echo "═══════════════════════════════════════════════════════"

cd "${SLURM_SUBMIT_DIR:-$(pwd)}"

VENV_DIR="${HTR_VENV:-.venv}"
if [ ! -f "$VENV_DIR/bin/activate" ]; then
    echo "✗ Virtualenv no encontrado en $VENV_DIR"
    exit 1
fi
source "$VENV_DIR/bin/activate"
export PYTHONPATH="$(pwd):${PYTHONPATH:-}"

# ── Verificar prerequisito htr_cleaning_completed ─────────────────────
check_prerequisite() {
    local htr_id="$1"
    python - <<PYEOF
import os, sys
sys.path.insert(0, os.getcwd())
try:
    from database.migration.db import get_conn, Operations
    with get_conn() as conn:
        ok = Operations.has_completed(conn, "htr_cleaning_completed", "htr", $htr_id)
    sys.exit(0 if ok else 1)
except Exception as e:
    print(f"⚠ BD: {e}", file=sys.stderr)
    sys.exit(0)  # continuar si no hay BD
PYEOF
}

# ── Procesar htr por htr ──────────────────────────────────────────────
n_total=0
n_ok=0
n_fail=0
n_skip=0

while IFS= read -r htr_id; do
    [[ -z "$htr_id" || "$htr_id" == \#* ]] && continue
    n_total=$((n_total + 1))

    echo "  → htr_id=$htr_id"

    # Verificar prerequisito
    if ! check_prerequisite "$htr_id"; then
        echo "  ⚠ htr_id=$htr_id: htr_cleaning_completed no registrado, omitiendo."
        n_skip=$((n_skip + 1))
        continue
    fi

    # Ejecutar modernización
    if python pipeline/htr_descriptive_analysis/spanish_clean_modern.py \
            --htr-id "$htr_id" \
            --slurm-job-id "${SLURM_JOB_ID:-local}"; then
        n_ok=$((n_ok + 1))
        echo "  ✓ htr_id=$htr_id completado"
    else
        n_fail=$((n_fail + 1))
        echo "  ✗ htr_id=$htr_id falló"
    fi
done < "$BATCH_FILE"

# ── Resumen ───────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Resumen modernización"
echo "  Total    : $n_total"
echo "  OK       : $n_ok"
echo "  Fallos   : $n_fail"
echo "  Omitidos : $n_skip  (prerequisito pendiente)"
echo "  Fin      : $(date '+%Y-%m-%d %H:%M:%S')"
echo "═══════════════════════════════════════════════════════"

if [ "$n_fail" -gt 0 ]; then
    exit 1
fi
