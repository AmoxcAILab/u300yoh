#!/usr/bin/env bash
# infrastructure/slurm/job_typography_classification.sh
# ──────────────────────────────────────────────────────
# Job Slurm GPU: clasificación tipográfica de imágenes.
#
# Argumentos posicionales:
#   $1  BATCH_FILE  — ruta a archivo con una image_id por línea
#   $2  MODEL_DIR   — directorio del modelo de clasificación (opcional,
#                     default: $HTR_MODELS_DIR)
#
# Uso:
#   sbatch job_typography_classification.sh batch_imgs.txt models/typography/
#
#SBATCH --job-name=htr_typography
#SBATCH --output=slurm-logs/htr_typography_%j.out
#SBATCH --error=slurm-logs/htr_typography_%j.err
#SBATCH --partition=gpu
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=04:00:00

set -euo pipefail

# ── Argumentos ────────────────────────────────────────────────────────
BATCH_FILE="${1:-}"
MODEL_DIR="${2:-${HTR_MODELS_DIR:-$(pwd)/data_ingestion/models}}"

if [ -z "$BATCH_FILE" ]; then
    echo "✗ Falta BATCH_FILE como primer argumento."
    echo "  Uso: sbatch job_typography_classification.sh <batch_file> [model_dir]"
    exit 1
fi

if [ ! -f "$BATCH_FILE" ]; then
    echo "✗ Archivo batch no encontrado: $BATCH_FILE"
    exit 1
fi

# ── Entorno ───────────────────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════"
echo "  HTR Pipeline — Clasificación Tipográfica"
echo "═══════════════════════════════════════════════════════"
echo "  Job ID    : ${SLURM_JOB_ID:-local}"
echo "  Nodo      : ${SLURMD_NODENAME:-$(hostname)}"
echo "  Batch     : $BATCH_FILE"
echo "  Models    : $MODEL_DIR"
echo "  Fecha     : $(date '+%Y-%m-%d %H:%M:%S')"
echo "═══════════════════════════════════════════════════════"

cd "${SLURM_SUBMIT_DIR:-$(pwd)}"

# Activar entorno Python
VENV_DIR="${HTR_VENV:-.venv}"
if [ ! -f "$VENV_DIR/bin/activate" ]; then
    echo "✗ Virtualenv no encontrado en $VENV_DIR"
    exit 1
fi
source "$VENV_DIR/bin/activate"
export PYTHONPATH="$(pwd):${PYTHONPATH:-}"

# ── Registrar inicio del job en BD ────────────────────────────────────
python - <<PYEOF
import os, sys
sys.path.insert(0, os.getcwd())
try:
    from database.migration.db import get_conn, Operations
    with get_conn() as conn:
        op_id = Operations.record(
            conn,
            operation_type="typography_classified",
            slurm_job_id=os.environ.get("SLURM_JOB_ID", "local"),
            status="running",
        )
    print(f"  operation_id (batch): {op_id}")
except Exception as e:
    print(f"⚠ No se pudo registrar inicio en BD: {e}", file=sys.stderr)
PYEOF

# ── Procesar imagen por imagen ────────────────────────────────────────
n_total=0
n_ok=0
n_fail=0

while IFS= read -r image_id; do
    # Ignorar líneas vacías y comentarios
    [[ -z "$image_id" || "$image_id" == \#* ]] && continue
    n_total=$((n_total + 1))

    echo "  → image_id=$image_id"
    if python data_ingestion/typography_classification.py \
            --image-id "$image_id" \
            --model-dir "$MODEL_DIR"; then
        n_ok=$((n_ok + 1))
    else
        n_fail=$((n_fail + 1))
        echo "  ⚠ Falló image_id=$image_id"
    fi
done < "$BATCH_FILE"

# ── Resumen ───────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Resumen clasificación tipográfica"
echo "  Total   : $n_total"
echo "  OK      : $n_ok"
echo "  Fallos  : $n_fail"
echo "  Fin     : $(date '+%Y-%m-%d %H:%M:%S')"
echo "═══════════════════════════════════════════════════════"

if [ "$n_fail" -gt 0 ]; then
    exit 1
fi
