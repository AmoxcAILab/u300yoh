#!/usr/bin/env bash
# infrastructure/slurm/job_historical_clean.sh
# ──────────────────────────────────────────────────────
# Job Slurm GPU: limpieza histórica de HTR con el modelo
# spanish_historical_clean.
#
# Para cada htr_id en el batch:
#   1. Registra htr_cleaning_started sobre el htr
#   2. Ejecuta spanish_historical_clean → genera hist_clean
#   3. Registra htr_cleaning_completed + descriptive_analysis_computed
#
# Argumentos posicionales:
#   $1  BATCH_FILE  — ruta a archivo con una htr_id por línea
#
# Uso:
#   sbatch job_historical_clean.sh batch_htr.txt
#
#SBATCH --job-name=htr_historical_clean
#SBATCH --output=slurm-logs/htr_historical_clean_%j.out
#SBATCH --error=slurm-logs/htr_historical_clean_%j.err
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
    echo "  Uso: sbatch job_historical_clean.sh <batch_file>"
    exit 1
fi

if [ ! -f "$BATCH_FILE" ]; then
    echo "✗ Archivo batch no encontrado: $BATCH_FILE"
    exit 1
fi

# ── Entorno ───────────────────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════"
echo "  HTR Pipeline — Limpieza Histórica (spanish_historical_clean)"
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

# ── Procesar htr por htr ──────────────────────────────────────────────
n_total=0
n_ok=0
n_fail=0

while IFS= read -r htr_id; do
    [[ -z "$htr_id" || "$htr_id" == \#* ]] && continue
    n_total=$((n_total + 1))

    echo "  → htr_id=$htr_id"

    # Registrar inicio
    python - <<PYEOF
import os, sys
sys.path.insert(0, os.getcwd())
try:
    from database.migration.db import get_conn, Operations
    with get_conn() as conn:
        Operations.record_and_link(
            conn,
            operation_type="htr_cleaning_started",
            entity="htr",
            entity_id=$htr_id,
            slurm_job_id=os.environ.get("SLURM_JOB_ID", "local"),
            status="running",
        )
except Exception as e:
    print(f"⚠ BD: {e}", file=sys.stderr)
PYEOF

    # Ejecutar pipeline/htr_descriptive_analysis/spanish_historical_clean
    # (el script toma htr_id y produce hist_clean + métricas)
    if python pipeline/htr_descriptive_analysis/spanish_historical_clean.py \
            --htr-id "$htr_id" \
            --slurm-job-id "${SLURM_JOB_ID:-local}"; then
        n_ok=$((n_ok + 1))
        echo "  ✓ htr_id=$htr_id completado"
    else
        n_fail=$((n_fail + 1))
        echo "  ✗ htr_id=$htr_id falló"
        # Actualizar operación a failed
        python - <<PYEOF
import os, sys
sys.path.insert(0, os.getcwd())
try:
    from database.migration.db import get_conn, Operations
    with get_conn() as conn:
        last = Operations.get_last(conn, "htr_cleaning_started", "htr", $htr_id)
        if last:
            Operations.update_status(conn, last["operation_id"], "failed")
except Exception as e:
    print(f"⚠ BD: {e}", file=sys.stderr)
PYEOF
    fi
done < "$BATCH_FILE"

# ── Resumen ───────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Resumen limpieza histórica"
echo "  Total   : $n_total"
echo "  OK      : $n_ok"
echo "  Fallos  : $n_fail"
echo "  Fin     : $(date '+%Y-%m-%d %H:%M:%S')"
echo "═══════════════════════════════════════════════════════"

if [ "$n_fail" -gt 0 ]; then
    exit 1
fi
