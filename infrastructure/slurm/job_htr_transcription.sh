#!/usr/bin/env bash
# infrastructure/slurm/job_htr_transcription.sh
# ─────────────────────────────────────────────────────────
# Job Slurm GPU: transcripción HTR vía API Transkribus.
#
# Prerequisitos por imagen en el batch:
#   - layout_retrieved completado (transkribus_job_id disponible)
#   - typography_classified completado (calligraphy_type disponible)
#
# El script selecciona automáticamente el modelo HTR según el tipo
# de caligrafía registrado en la operación typography_classified,
# reutilizando el layout existente (sin volver a llamar al API de layout).
#
# Argumentos posicionales:
#   $1  BATCH_FILE  — ruta a archivo con una image_id por línea
#   $2  MODEL_DIR   — directorio con modelos HTR (opcional,
#                     default: $HTR_MODELS_DIR)
#
# Uso:
#   sbatch job_htr_transcription.sh batch_imgs.txt models/
#
#SBATCH --job-name=htr_transcription
#SBATCH --output=slurm-logs/htr_transcription_%j.out
#SBATCH --error=slurm-logs/htr_transcription_%j.err
#SBATCH --partition=gpu
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=4
#SBATCH --mem=24G
#SBATCH --time=08:00:00

set -euo pipefail

# ── Argumentos ────────────────────────────────────────────────────────
BATCH_FILE="${1:-}"
MODEL_DIR="${2:-${HTR_MODELS_DIR:-$(pwd)/data_ingestion/models}}"

if [ -z "$BATCH_FILE" ]; then
    echo "✗ Falta BATCH_FILE como primer argumento."
    echo "  Uso: sbatch job_htr_transcription.sh <batch_file> [model_dir]"
    exit 1
fi

if [ ! -f "$BATCH_FILE" ]; then
    echo "✗ Archivo batch no encontrado: $BATCH_FILE"
    exit 1
fi

# ── Entorno ───────────────────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════"
echo "  HTR Pipeline — Transcripción HTR (Transkribus)"
echo "═══════════════════════════════════════════════════════"
echo "  Job ID    : ${SLURM_JOB_ID:-local}"
echo "  Nodo      : ${SLURMD_NODENAME:-$(hostname)}"
echo "  Batch     : $BATCH_FILE"
echo "  Models    : $MODEL_DIR"
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

# ── Procesar imagen por imagen ────────────────────────────────────────
n_total=0
n_ok=0
n_fail=0

while IFS= read -r image_id; do
    [[ -z "$image_id" || "$image_id" == \#* ]] && continue
    n_total=$((n_total + 1))

    echo "  → image_id=$image_id"

    # trigger_htr_transcription.py:
    #   1. Recupera transkribus_job_id del layout (operación layout_retrieved)
    #   2. Lee calligraphy_type (operación typography_classified)
    #   3. Selecciona modelo HTR de MODEL_DIR según calligraphy_type
    #   4. Llama API Transkribus con layout existente + modelo
    #   5. Descarga HTR → data_ingestion/transkribús/collection/document/htr_file.txt
    #   6. Registra htr en tabla htr + operación htr_available
    if python data_ingestion/trigger_htr_transcription.py \
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
echo "  Resumen transcripción HTR"
echo "  Total   : $n_total"
echo "  OK      : $n_ok"
echo "  Fallos  : $n_fail"
echo "  Fin     : $(date '+%Y-%m-%d %H:%M:%S')"
echo "═══════════════════════════════════════════════════════"

if [ "$n_fail" -gt 0 ]; then
    exit 1
fi
