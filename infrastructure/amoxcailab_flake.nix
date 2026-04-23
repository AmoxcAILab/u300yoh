{
  # AmoxcAILab — Pipeline HTR completo, Schmidt Sciences cluster
  # Renombrar a flake.nix (o symlink) para que nix develop lo detecte.
  description = "AmoxcAILab HTR Pipeline — Schmidt Sciences";

  inputs = {
    nixpkgs.url     = "github:NixOS/nixpkgs/nixos-24.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = false;
        };

        # ── PostgreSQL 15 con pgvector ─────────────────────────────
        postgresql = pkgs.postgresql_15.withPackages (ps: [ ps.pgvector ]);

        # ── Python 3.11 ────────────────────────────────────────────
        python = pkgs.python311;

        pythonEnv = python.withPackages (ps: with ps; [
          pip virtualenv
          numpy scipy scikit-learn pandas matplotlib pillow
          requests tqdm regex six packaging python-dateutil
          psycopg2
        ]);

        # ── Variables de entorno ───────────────────────────────────
        dbEnvVars = ''
          export HTR_PGDATA="''${HTR_PGDATA:-$HOME/.local/share/htr-pipeline/pgdata}"
          export HTR_PGRUN="''${HTR_PGRUN:-$HOME/.local/share/htr-pipeline/run}"
          export HTR_PGPORT="''${HTR_PGPORT:-5433}"
          export HTR_PGDB="''${HTR_PGDB:-htr_pipeline}"
          export HTR_PGUSER="''${HTR_PGUSER:-$USER}"

          export PGDATA="$HTR_PGDATA"
          export PGHOST="$HTR_PGRUN"
          export PGPORT="$HTR_PGPORT"
          export PGDATABASE="$HTR_PGDB"
          export PGUSER="$HTR_PGUSER"

          export HTR_DB_URL="postgresql://$HTR_PGUSER@/$HTR_PGDB?host=$HTR_PGRUN&port=$HTR_PGPORT"

          # Modelos locales y colaborador activo
          export HTR_MODELS_DIR="''${HTR_MODELS_DIR:-$(pwd)/data_ingestion/models}"
          export HTR_COLLABORATOR_ID="''${HTR_COLLABORATOR_ID:-}"

          # Directorio raíz del proyecto (para PYTHONPATH y paths de scripts)
          export HTR_PIPELINE_DIR="''${HTR_PIPELINE_DIR:-$(pwd)}"
        '';

        # ── Helpers compartidos ────────────────────────────────────
        # Fragmentos de shell reutilizados dentro de los scripts.
        venvCheck = ''
          VENV_DIR="''${HTR_VENV:-.venv}"
          if [ ! -f "$VENV_DIR/bin/python" ]; then
            echo "✗ Virtualenv no encontrado en $VENV_DIR"
            echo "  Ejecuta primero: htr-setup-venv"
            exit 1
          fi
          PYTHON="$VENV_DIR/bin/python"
          export PYTHONPATH="$HTR_PIPELINE_DIR''${PYTHONPATH:+:$PYTHONPATH}"
        '';

        dbCheck = ''
          if ! ${postgresql}/bin/pg_isready \
               -h "$HTR_PGRUN" -p "$HTR_PGPORT" -q 2>/dev/null; then
            echo "✗ PostgreSQL no está corriendo."
            echo "  Ejecuta: htr-db-start"
            exit 1
          fi
        '';

        # Selecciona collection_id: desde BD si disponible, si no pide input manual.
        fzfCollectionPicker = ''
          _pick_collection_id() {
            if ${postgresql}/bin/pg_isready \
                 -h "$HTR_PGRUN" -p "$HTR_PGPORT" -q 2>/dev/null; then
              local row
              row=$(${postgresql}/bin/psql \
                -h "$HTR_PGRUN" -p "$HTR_PGPORT" -d "$HTR_PGDB" \
                -tAF'|' \
                -c "SELECT collection_id, collection_name, collection_type FROM public.collections ORDER BY collection_id;" \
                2>/dev/null \
                | ${pkgs.fzf}/bin/fzf \
                    --prompt "Colección > " \
                    --header "ID | nombre | tipo" \
                    --delimiter '|' \
                    --preview 'echo "collection_id: {1}"' \
                    --height 15 --border)
              echo "$row" | cut -d'|' -f1 | tr -d ' '
            else
              echo "⚠ BD no disponible. Introduce collection_id:" >&2
              read -r _cid
              echo "$_cid"
            fi
          }
        '';


        # ══════════════════════════════════════════════════════════
        # SCRIPTS DE BASE DE DATOS (heredados, sin cambios de nombre)
        # ══════════════════════════════════════════════════════════

        dbInitScript = pkgs.writeShellScriptBin "htr_db_init" ''
          set -euo pipefail
          ${dbEnvVars}

          echo "→ HTR_PGDATA : $HTR_PGDATA"
          echo "→ HTR_PGPORT : $HTR_PGPORT"
          echo "→ HTR_PGDB   : $HTR_PGDB"

          mkdir -p "$HTR_PGDATA" "$HTR_PGRUN"

          if [ ! -f "$HTR_PGDATA/PG_VERSION" ]; then
            echo "▶ Inicializando cluster PostgreSQL..."
            ${postgresql}/bin/initdb \
              --pgdata="$HTR_PGDATA" \
              --auth=trust \
              --no-locale \
              --encoding=UTF8
            echo "✓ Cluster inicializado."
          else
            echo "✓ Cluster ya existe. Saltando initdb."
          fi

          cat >> "$HTR_PGDATA/postgresql.conf" << 'PGCONF'

# HTR pipeline — configuración generada por htr_db_init
unix_socket_directories = 'HTR_PGRUN_PLACEHOLDER'
port = HTR_PGPORT_PLACEHOLDER
listen_addresses = ''
shared_preload_libraries = 'vector'
log_min_messages = warning
log_min_error_statement = error
PGCONF
          # Sustituir placeholders con valores reales
          sed -i \
            -e "s|HTR_PGRUN_PLACEHOLDER|$HTR_PGRUN|g" \
            -e "s|HTR_PGPORT_PLACEHOLDER|$HTR_PGPORT|g" \
            "$HTR_PGDATA/postgresql.conf"

          echo "▶ Iniciando PostgreSQL..."
          ${postgresql}/bin/pg_ctl \
            -D "$HTR_PGDATA" \
            -l "$HTR_PGDATA/postgresql.log" \
            start -w -t 15

          ${postgresql}/bin/pg_isready -h "$HTR_PGRUN" -p "$HTR_PGPORT" \
            && echo "✓ PostgreSQL listo." \
            || { echo "✗ No responde. Ver $HTR_PGDATA/postgresql.log"; exit 1; }

          if ! ${postgresql}/bin/psql \
               -h "$HTR_PGRUN" -p "$HTR_PGPORT" \
               -lqt | cut -d'|' -f1 | grep -qw "$HTR_PGDB"; then
            echo "▶ Creando base de datos '$HTR_PGDB'..."
            ${postgresql}/bin/createdb \
              -h "$HTR_PGRUN" -p "$HTR_PGPORT" "$HTR_PGDB"
            echo "✓ Base de datos creada."
          else
            echo "✓ Base de datos '$HTR_PGDB' ya existe."
          fi

          echo ""
          echo "═══════════════════════════════════════════"
          echo "  BD lista. Siguiente paso:"
          echo "  htr_db_schema database/schema.sql"
          echo "═══════════════════════════════════════════"
        '';

        dbStartScript = pkgs.writeShellScriptBin "htr_db_start" ''
          set -euo pipefail
          ${dbEnvVars}

          if ${postgresql}/bin/pg_isready \
               -h "$HTR_PGRUN" -p "$HTR_PGPORT" -q 2>/dev/null; then
            echo "✓ PostgreSQL ya está corriendo en puerto $HTR_PGPORT."
            exit 0
          fi

          if [ ! -f "$HTR_PGDATA/PG_VERSION" ]; then
            echo "✗ Cluster no inicializado. Corre primero: htr_db_init"
            exit 1
          fi

          echo "▶ Iniciando PostgreSQL..."
          ${postgresql}/bin/pg_ctl \
            -D "$HTR_PGDATA" \
            -l "$HTR_PGDATA/postgresql.log" \
            start -w -t 15
          ${postgresql}/bin/pg_isready \
            -h "$HTR_PGRUN" -p "$HTR_PGPORT" \
            && echo "✓ PostgreSQL listo." \
            || { echo "✗ No responde. Ver $HTR_PGDATA/postgresql.log"; exit 1; }
        '';

        dbStopScript = pkgs.writeShellScriptBin "htr_db_stop" ''
          set -euo pipefail
          ${dbEnvVars}
          echo "▶ Deteniendo PostgreSQL..."
          ${postgresql}/bin/pg_ctl -D "$HTR_PGDATA" stop -m fast \
            && echo "✓ PostgreSQL detenido." \
            || echo "✗ No se pudo detener."
        '';

        dbSchemaScript = pkgs.writeShellScriptBin "htr_db_schema" ''
          set -euo pipefail
          ${dbEnvVars}

          SCHEMA_FILE="''${1:-database/schema.sql}"

          if [ ! -f "$SCHEMA_FILE" ]; then
            echo "✗ No se encontró: $SCHEMA_FILE"
            echo "  Uso: htr_db_schema [ruta/schema.sql]"
            exit 1
          fi

          echo "▶ Aplicando schema desde: $SCHEMA_FILE"
          ${postgresql}/bin/psql \
            -h "$HTR_PGRUN" -p "$HTR_PGPORT" \
            -d "$HTR_PGDB" \
            -f "$SCHEMA_FILE" \
            -v ON_ERROR_STOP=1 \
            -v ECHO=errors
          echo "✓ Schema aplicado."

          echo ""
          echo "▶ Extensiones activas:"
          ${postgresql}/bin/psql \
            -h "$HTR_PGRUN" -p "$HTR_PGPORT" \
            -d "$HTR_PGDB" \
            -c "SELECT extname, extversion FROM pg_extension ORDER BY extname;"
        '';

        dbStatusScript = pkgs.writeShellScriptBin "htr_db_status" ''
          set -euo pipefail
          ${dbEnvVars}

          echo "═══════════════════════════════════════════"
          echo "  Estado de la BD"
          echo "═══════════════════════════════════════════"
          echo "  PGDATA  : $HTR_PGDATA"
          echo "  Socket  : $HTR_PGRUN"
          echo "  Puerto  : $HTR_PGPORT"
          echo "  Base    : $HTR_PGDB"
          echo "  DB_URL  : $HTR_DB_URL"
          echo "───────────────────────────────────────────"

          if ${postgresql}/bin/pg_isready \
               -h "$HTR_PGRUN" -p "$HTR_PGPORT" -q 2>/dev/null; then
            echo "  PostgreSQL: ✓ corriendo"
            echo ""
            echo "▶ Colecciones registradas:"
            ${postgresql}/bin/psql \
              -h "$HTR_PGRUN" -p "$HTR_PGPORT" \
              -d "$HTR_PGDB" \
              -c "SELECT collection_id, collection_name, collection_type FROM public.collections ORDER BY collection_id;" \
              2>/dev/null || echo "  (schema aún no aplicado)"
          else
            echo "  PostgreSQL: ✗ no está corriendo"
            echo "  Ejecuta: htr_db_start"
          fi
        '';

        # ── Setup venv ─────────────────────────────────────────────
        setupVenvScript = pkgs.writeShellScriptBin "htr_setup_venv" ''
          set -euo pipefail

          VENV_DIR="''${1:-.venv}"
          REQUIREMENTS="''${2:-requirements.txt}"

          if [ ! -f "$REQUIREMENTS" ]; then
            echo "✗ No se encontró: $REQUIREMENTS"
            echo "  Uso: htr_setup_venv [directorio_venv] [requirements.txt]"
            exit 1
          fi

          echo "▶ Creando virtualenv en $VENV_DIR..."
          ${python}/bin/python -m venv "$VENV_DIR"

          echo "▶ Actualizando pip/setuptools/wheel..."
          "$VENV_DIR/bin/pip" install --quiet --upgrade pip setuptools wheel

          echo "▶ Instalando dependencias..."
          "$VENV_DIR/bin/pip" install --quiet -r "$REQUIREMENTS"

          echo ""
          echo "✓ Virtualenv listo en $VENV_DIR"
          echo "  Para activar: source $VENV_DIR/bin/activate"
        '';

        # ── Gestión de paquetes pip ────────────────────────────────
        pipInstallScript = pkgs.writeShellScriptBin "htr_pip_install" ''
          set -euo pipefail

          if [ $# -eq 0 ]; then
            echo "Uso: htr_pip_install <paquete> [paquete2 ...]"
            exit 1
          fi

          VENV_DIR="''${HTR_VENV:-.venv}"
          REQUIREMENTS="''${HTR_REQUIREMENTS:-requirements.txt}"

          if [ ! -f "$VENV_DIR/bin/pip" ]; then
            echo "✗ Virtualenv no encontrado en $VENV_DIR"
            echo "  Ejecuta: htr_setup_venv"
            exit 1
          fi

          echo "▶ Instalando: $*"
          "$VENV_DIR/bin/pip" install "$@"

          echo "▶ Actualizando $REQUIREMENTS..."
          "$VENV_DIR/bin/pip" freeze > "$REQUIREMENTS"
          echo "✓ $REQUIREMENTS actualizado."
        '';

        pipRemoveScript = pkgs.writeShellScriptBin "htr_pip_remove" ''
          set -euo pipefail

          if [ $# -eq 0 ]; then
            echo "Uso: htr_pip_remove <paquete> [paquete2 ...]"
            exit 1
          fi

          VENV_DIR="''${HTR_VENV:-.venv}"
          REQUIREMENTS="''${HTR_REQUIREMENTS:-requirements.txt}"

          if [ ! -f "$VENV_DIR/bin/pip" ]; then
            echo "✗ Virtualenv no encontrado en $VENV_DIR"
            exit 1
          fi

          echo "▶ Desinstalando: $*"
          "$VENV_DIR/bin/pip" uninstall -y "$@"

          echo "▶ Actualizando $REQUIREMENTS..."
          "$VENV_DIR/bin/pip" freeze > "$REQUIREMENTS"
          echo "✓ $REQUIREMENTS actualizado."
        '';


        # ══════════════════════════════════════════════════════════
        # SCRIPTS DE INGESTA DE DATOS
        # ══════════════════════════════════════════════════════════

        registerCollectionScript = pkgs.writeShellScriptBin "htr_register_collection" ''
          set -euo pipefail
          ${dbEnvVars}
          ${venvCheck}
          ${dbCheck}

          cd "$HTR_PIPELINE_DIR"
          "$PYTHON" data_ingestion/register_collection.py "$@"
        '';

        downloadImagesScript = pkgs.writeShellScriptBin "htr_download_images" ''
          set -euo pipefail
          ${dbEnvVars}
          ${venvCheck}
          ${dbCheck}

          # Selección interactiva de colección si no se pasa --collection-id
          if [[ "$*" != *"--collection-id"* ]]; then
            ${fzfCollectionPicker}
            COL_ID=$(_pick_collection_id)
            if [ -z "$COL_ID" ]; then
              echo "✗ No se seleccionó colección."
              exit 1
            fi
            echo "▶ Colección seleccionada: $COL_ID"
            set -- --collection-id "$COL_ID" "$@"
          fi

          cd "$HTR_PIPELINE_DIR"
          "$PYTHON" data_ingestion/import_collection.py "$@"
        '';

        registerGroundTruthScript = pkgs.writeShellScriptBin "htr_register_ground_truth" ''
          set -euo pipefail
          ${dbEnvVars}
          ${venvCheck}
          ${dbCheck}

          if [[ "$*" != *"--collection-id"* ]]; then
            ${fzfCollectionPicker}
            COL_ID=$(_pick_collection_id)
            if [ -z "$COL_ID" ]; then
              echo "✗ No se seleccionó colección."
              exit 1
            fi
            set -- --collection-id "$COL_ID" "$@"
          fi

          cd "$HTR_PIPELINE_DIR"
          "$PYTHON" data_ingestion/register_ground_truth.py "$@"
        '';

        registerModelScript = pkgs.writeShellScriptBin "htr_register_model" ''
          set -euo pipefail
          ${dbEnvVars}
          ${venvCheck}
          ${dbCheck}

          MODEL_NAME="''${1:-}"
          MODEL_PATH="''${2:-}"
          MODEL_TYPE="''${3:-htr}"

          if [ -z "$MODEL_NAME" ] || [ -z "$MODEL_PATH" ]; then
            echo "Uso: htr_register_model <nombre> <ruta> [tipo]"
            echo "  tipo: htr | typography | layout  (default: htr)"
            exit 1
          fi

          cd "$HTR_PIPELINE_DIR"
          "$PYTHON" - <<PYEOF
import sys
sys.path.insert(0, "$HTR_PIPELINE_DIR")
from database.migration.db import get_conn
from database.crud_operations import Models

with get_conn() as conn:
    mid = Models.create(
        conn,
        model_name="$MODEL_NAME",
        model_path="$MODEL_PATH",
        model_type="$MODEL_TYPE",
    )
    print(f"✓ Modelo registrado: ID={mid}  nombre='$MODEL_NAME'  tipo='$MODEL_TYPE'")
PYEOF
        '';

        knowledgeBaseRebuildScript = pkgs.writeShellScriptBin "htr_knowledge_base_rebuild" ''
          set -euo pipefail
          ${dbEnvVars}
          ${venvCheck}
          ${dbCheck}

          echo "▶ Reconstruyendo knowledge base..."
          cd "$HTR_PIPELINE_DIR"
          "$PYTHON" data_ingestion/build_knowledge_base.py "$@"
        '';


        # ══════════════════════════════════════════════════════════
        # ANOTACIONES: EXPORTAR / SINCRONIZAR
        # ══════════════════════════════════════════════════════════

        exportForAnnotationScript = pkgs.writeShellScriptBin "htr_export_for_annotation" ''
          set -euo pipefail
          ${dbEnvVars}
          ${venvCheck}
          ${dbCheck}

          if [[ "$*" != *"--collection-id"* ]]; then
            ${fzfCollectionPicker}
            COL_ID=$(_pick_collection_id)
            if [ -z "$COL_ID" ]; then
              echo "✗ No se seleccionó colección."
              exit 1
            fi
            set -- --collection-id "$COL_ID" "$@"
          fi

          cd "$HTR_PIPELINE_DIR"
          "$PYTHON" database/export_for_annotation.py "$@"
        '';

        syncAnnotationsScript = pkgs.writeShellScriptBin "htr_sync_annotations" ''
          set -euo pipefail
          ${dbEnvVars}
          ${venvCheck}
          ${dbCheck}

          cd "$HTR_PIPELINE_DIR"
          "$PYTHON" database/sync_annotations.py "$@"
        '';


        # ══════════════════════════════════════════════════════════
        # OBSERVABILIDAD
        # ══════════════════════════════════════════════════════════

        operationsLogScript = pkgs.writeShellScriptBin "htr_operations_log" ''
          set -euo pipefail
          ${dbEnvVars}

          if ! ${postgresql}/bin/pg_isready \
               -h "$HTR_PGRUN" -p "$HTR_PGPORT" -q 2>/dev/null; then
            echo "✗ PostgreSQL no disponible. Ejecuta: htr_db_start"
            exit 1
          fi

          # Muestra las últimas operaciones filtrables con fzf
          ${postgresql}/bin/psql \
            -h "$HTR_PGRUN" -p "$HTR_PGPORT" -d "$HTR_PGDB" \
            -tAF'|' \
            -c "
              SELECT
                o.operation_id,
                ot.operation_type_name,
                o.status,
                to_char(o.logged_at, 'YYYY-MM-DD HH24:MI') AS logged_at,
                COALESCE(c.collaborator_name, '—') AS collaborator,
                COALESCE(o.slurm_job_id, o.transkribus_job_id, '') AS job_id
              FROM public.operations o
              JOIN public.operation_types ot USING (operation_type_id)
              LEFT JOIN public.collaborators c USING (collaborator_id)
              ORDER BY o.logged_at DESC
              LIMIT 500;
            " 2>/dev/null \
          | ${pkgs.fzf}/bin/fzf \
              --prompt "Operación > " \
              --header "ID | tipo | estado | fecha | colaborador | job_id" \
              --delimiter '|' \
              --height 80% \
              --border \
              --preview '
                echo "Entidades vinculadas:"
                psql -h "$HTR_PGRUN" -p "$HTR_PGPORT" -d "$HTR_PGDB" \
                  -c "SELECT * FROM public.collections_operations WHERE operation_id = {1}
                      UNION ALL
                      SELECT * FROM public.documents_operations WHERE operation_id = {1}
                      UNION ALL
                      SELECT * FROM public.images_operations WHERE operation_id = {1}
                      UNION ALL
                      SELECT * FROM public.htr_operations WHERE operation_id = {1};" 2>/dev/null
              ' \
              --preview-window right:40% \
          || true
        '';

        pipelineStatusScript = pkgs.writeShellScriptBin "htr_pipeline_status" ''
          set -euo pipefail
          ${dbEnvVars}

          if ! ${postgresql}/bin/pg_isready \
               -h "$HTR_PGRUN" -p "$HTR_PGPORT" -q 2>/dev/null; then
            echo "✗ PostgreSQL no disponible. Ejecuta: htr_db_start"
            exit 1
          fi

          echo "═══════════════════════════════════════════════════════"
          echo "  Estado del Pipeline por Colección"
          echo "═══════════════════════════════════════════════════════"
          ${postgresql}/bin/psql \
            -h "$HTR_PGRUN" -p "$HTR_PGPORT" -d "$HTR_PGDB" \
            -c "SELECT * FROM public.v_pipeline_status ORDER BY collection_name;" \
            2>/dev/null || echo "  (vista no disponible — aplica el schema primero)"

          echo ""
          echo "═══════════════════════════════════════════════════════"
          echo "  Pendientes de procesamiento"
          echo "═══════════════════════════════════════════════════════"
          ${postgresql}/bin/psql \
            -h "$HTR_PGRUN" -p "$HTR_PGPORT" -d "$HTR_PGDB" \
            -c "SELECT * FROM public.v_pipeline_pending LIMIT 20;" \
            2>/dev/null || echo "  (vista no disponible)"
        '';


        # ══════════════════════════════════════════════════════════
        # WRAPPERS SLURM
        # ══════════════════════════════════════════════════════════

        slurmTypographyScript = pkgs.writeShellScriptBin "htr_slurm_typography_classification" ''
          set -euo pipefail
          ${dbEnvVars}

          BATCH_FILE="''${1:-}"
          if [ -z "$BATCH_FILE" ]; then
            echo "Uso: htr_slurm_typography_classification <batch_file> [model_dir]"
            echo "  batch_file : archivo con una image_id por línea"
            echo "  model_dir  : directorio del modelo (default: \$HTR_MODELS_DIR)"
            exit 1
          fi

          MODEL_DIR="''${2:-$HTR_MODELS_DIR}"
          SCRIPT="$HTR_PIPELINE_DIR/infrastructure/slurm/job_typography_classification.sh"

          if [ ! -f "$SCRIPT" ]; then
            echo "✗ Script no encontrado: $SCRIPT"
            exit 1
          fi

          echo "▶ Enviando job de clasificación tipográfica..."
          echo "  batch_file : $BATCH_FILE"
          echo "  model_dir  : $MODEL_DIR"
          sbatch "$SCRIPT" "$BATCH_FILE" "$MODEL_DIR"
        '';

        slurmHtrTranscriptionScript = pkgs.writeShellScriptBin "htr_slurm_htr_transcription" ''
          set -euo pipefail
          ${dbEnvVars}

          BATCH_FILE="''${1:-}"
          if [ -z "$BATCH_FILE" ]; then
            echo "Uso: htr_slurm_htr_transcription <batch_file> [model_dir]"
            echo "  batch_file : archivo con una image_id por línea"
            echo "  model_dir  : directorio del modelo HTR (default: \$HTR_MODELS_DIR)"
            exit 1
          fi

          MODEL_DIR="''${2:-$HTR_MODELS_DIR}"
          SCRIPT="$HTR_PIPELINE_DIR/infrastructure/slurm/job_htr_transcription.sh"

          if [ ! -f "$SCRIPT" ]; then
            echo "✗ Script no encontrado: $SCRIPT"
            exit 1
          fi

          echo "▶ Enviando job de transcripción HTR..."
          echo "  batch_file : $BATCH_FILE"
          echo "  model_dir  : $MODEL_DIR"
          sbatch "$SCRIPT" "$BATCH_FILE" "$MODEL_DIR"
        '';

        slurmHistoricalCleanScript = pkgs.writeShellScriptBin "htr_slurm_historical_clean" ''
          set -euo pipefail
          ${dbEnvVars}

          BATCH_FILE="''${1:-}"
          if [ -z "$BATCH_FILE" ]; then
            echo "Uso: htr_slurm_historical_clean <batch_file>"
            echo "  batch_file : archivo con una htr_id por línea"
            exit 1
          fi

          SCRIPT="$HTR_PIPELINE_DIR/infrastructure/slurm/job_historical_clean.sh"

          if [ ! -f "$SCRIPT" ]; then
            echo "✗ Script no encontrado: $SCRIPT"
            exit 1
          fi

          echo "▶ Enviando job spanish_historical_clean..."
          sbatch "$SCRIPT" "$BATCH_FILE"
        '';

        slurmCleanModernScript = pkgs.writeShellScriptBin "htr_slurm_clean_modern" ''
          set -euo pipefail
          ${dbEnvVars}

          BATCH_FILE="''${1:-}"
          if [ -z "$BATCH_FILE" ]; then
            echo "Uso: htr_slurm_clean_modern <batch_file>"
            echo "  batch_file : archivo con una htr_id por línea"
            exit 1
          fi

          SCRIPT="$HTR_PIPELINE_DIR/infrastructure/slurm/job_clean_modern.sh"

          if [ ! -f "$SCRIPT" ]; then
            echo "✗ Script no encontrado: $SCRIPT"
            exit 1
          fi

          echo "▶ Enviando job spanish_clean_modern..."
          sbatch "$SCRIPT" "$BATCH_FILE"
        '';


        # ══════════════════════════════════════════════════════════
        # MENÚ INTERACTIVO PRINCIPAL
        # ══════════════════════════════════════════════════════════

        menuScript = pkgs.writeShellScriptBin "htr_menu" ''
          set -euo pipefail
          ${dbEnvVars}

          # ── Estado de la BD ──────────────────────────────────────
          _db_online() {
            ${postgresql}/bin/pg_isready \
              -h "$HTR_PGRUN" -p "$HTR_PGPORT" -q 2>/dev/null
          }

          _db_status_line() {
            if _db_online; then
              echo "BD: ✓ corriendo (puerto $HTR_PGPORT)"
            else
              echo "BD: ✗ no disponible"
            fi
          }

          # ── Picker de colección ──────────────────────────────────
          ${fzfCollectionPicker}

          # ── Submenús ─────────────────────────────────────────────
          _menu_colecciones() {
            local opcion
            opcion=$(printf \
              "registrar_coleccion\ndescargar_imagenes\nregistrar_ground_truth\nexportar_para_anotacion\nvolver" \
              | ${pkgs.fzf}/bin/fzf \
                  --prompt "Colecciones > " \
                  --header "$(_db_status_line)" \
                  --height 12 --border)
            case "$opcion" in
              registrar_coleccion)
                echo "▶ Directorio fuente de la colección:"
                read -r src_dir
                echo "▶ Nombre de la colección:"
                read -r col_name
                echo "▶ Tipo (AGN / AGI / otro):"
                read -r col_type
                htr_register_collection \
                  --source-dir "$src_dir" \
                  --name "$col_name" \
                  --collection-type "$col_type"
                ;;
              descargar_imagenes)
                COL_ID=$(_pick_collection_id)
                [ -z "$COL_ID" ] && return
                echo "▶ Directorio fuente de imágenes:"
                read -r src_dir
                htr_download_images \
                  --collection-id "$COL_ID" \
                  --source-dir "$src_dir"
                ;;
              registrar_ground_truth)
                COL_ID=$(_pick_collection_id)
                [ -z "$COL_ID" ] && return
                echo "▶ Directorio de ground_truth:"
                read -r gt_dir
                htr_register_ground_truth \
                  --collection-id "$COL_ID" \
                  --ground-truth-dir "$gt_dir"
                ;;
              exportar_para_anotacion)
                COL_ID=$(_pick_collection_id)
                [ -z "$COL_ID" ] && return
                htr_export_for_annotation --collection-id "$COL_ID"
                ;;
            esac
          }

          _menu_htr() {
            local opcion
            opcion=$(printf \
              "estado_pipeline\nlog_operaciones\nenviar_clasificacion_tipografica\nenviar_transcripcion_htr\nenviar_limpieza_historica\nenviar_modernizacion\nvolver" \
              | ${pkgs.fzf}/bin/fzf \
                  --prompt "HTR > " \
                  --header "$(_db_status_line)" \
                  --height 14 --border)
            case "$opcion" in
              estado_pipeline)            htr_pipeline_status ;;
              log_operaciones)            htr_operations_log ;;
              enviar_clasificacion_tipografica)
                echo "▶ Archivo batch (image_ids):"
                read -r batch
                htr_slurm_typography_classification "$batch"
                ;;
              enviar_transcripcion_htr)
                echo "▶ Archivo batch (image_ids):"
                read -r batch
                htr_slurm_htr_transcription "$batch"
                ;;
              enviar_limpieza_historica)
                echo "▶ Archivo batch (htr_ids):"
                read -r batch
                htr_slurm_historical_clean "$batch"
                ;;
              enviar_modernizacion)
                echo "▶ Archivo batch (htr_ids):"
                read -r batch
                htr_slurm_clean_modern "$batch"
                ;;
            esac
          }

          _menu_base_de_datos() {
            local opcion
            opcion=$(printf \
              "iniciar_bd\ndetener_bd\naplicar_schema\nestado_bd\ncreate_backup\nvolver" \
              | ${pkgs.fzf}/bin/fzf \
                  --prompt "Base de datos > " \
                  --header "$(_db_status_line)" \
                  --height 12 --border)
            case "$opcion" in
              iniciar_bd)       htr_db_start ;;
              detener_bd)       htr_db_stop ;;
              aplicar_schema)   htr_db_schema ;;
              estado_bd)        htr_db_status ;;
              create_backup)
                echo "▶ Directorio de salida (default: .):"
                read -r out_dir
                out_dir="''${out_dir:-.}"
                VENV_DIR="''${HTR_VENV:-.venv}"
                export PYTHONPATH="$HTR_PIPELINE_DIR"
                "$VENV_DIR/bin/python" database/create_backup.py --output-dir "$out_dir"
                ;;
            esac
          }

          _menu_anotaciones() {
            local opcion
            opcion=$(printf \
              "sincronizar_anotaciones\nexportar_para_anotacion\nvolver" \
              | ${pkgs.fzf}/bin/fzf \
                  --prompt "Anotaciones > " \
                  --header "$(_db_status_line)" \
                  --height 10 --border)
            case "$opcion" in
              sincronizar_anotaciones)
                echo "▶ Directorio de anotaciones:"
                read -r ann_dir
                htr_sync_annotations --annotations-dir "$ann_dir"
                ;;
              exportar_para_anotacion)
                COL_ID=$(_pick_collection_id)
                [ -z "$COL_ID" ] && return
                htr_export_for_annotation --collection-id "$COL_ID"
                ;;
            esac
          }

          _menu_knowledge_base() {
            local opcion
            opcion=$(printf \
              "reconstruir_knowledge_base\nvolver" \
              | ${pkgs.fzf}/bin/fzf \
                  --prompt "Knowledge base > " \
                  --header "$(_db_status_line)" \
                  --height 8 --border)
            case "$opcion" in
              reconstruir_knowledge_base) htr_knowledge_base_rebuild ;;
            esac
          }

          _menu_modelos() {
            local opcion
            opcion=$(printf \
              "registrar_modelo\nlistar_modelos\nvolver" \
              | ${pkgs.fzf}/bin/fzf \
                  --prompt "Modelos > " \
                  --header "$(_db_status_line)" \
                  --height 9 --border)
            case "$opcion" in
              registrar_modelo)
                echo "▶ Nombre del modelo:"
                read -r mname
                echo "▶ Ruta del modelo:"
                read -r mpath
                echo "▶ Tipo (htr / typography / layout):"
                read -r mtype
                htr_register_model "$mname" "$mpath" "''${mtype:-htr}"
                ;;
              listar_modelos)
                if _db_online; then
                  ${postgresql}/bin/psql \
                    -h "$HTR_PGRUN" -p "$HTR_PGPORT" -d "$HTR_PGDB" \
                    -c "SELECT model_id, model_name, model_type, model_path FROM public.models ORDER BY model_id;"
                else
                  echo "BD no disponible."
                fi
                ;;
            esac
          }

          # ── Bucle principal del menú ─────────────────────────────
          while true; do
            OPCION=$(printf \
              "colecciones\nhtr\nmodelos\nbase_de_datos\nanotaciones\nknowledge_base\nsalir" \
              | ${pkgs.fzf}/bin/fzf \
                  --prompt "AmoxcAILab > " \
                  --header "$(printf '═══ AmoxcAILab HTR Pipeline ═══\n%s' "$(_db_status_line)")" \
                  --height 14 \
                  --border \
                  --no-info \
                  --cycle) || break

            case "$OPCION" in
              colecciones)    _menu_colecciones ;;
              htr)            _menu_htr ;;
              modelos)        _menu_modelos ;;
              base_de_datos)  _menu_base_de_datos ;;
              anotaciones)    _menu_anotaciones ;;
              knowledge_base) _menu_knowledge_base ;;
              salir|"")       break ;;
            esac
          done

          echo "Hasta luego."
        '';


      in {
        # ── Paquetes exportados ──────────────────────────────────────
        packages = {
          inherit postgresql pythonEnv;
        };

        # ── Apps (nix run .#nombre) ──────────────────────────────────
        apps = {
          # BD
          htr_db_init    = { type = "app"; program = "${dbInitScript}/bin/htr_db_init"; };
          htr_db_start   = { type = "app"; program = "${dbStartScript}/bin/htr_db_start"; };
          htr_db_stop    = { type = "app"; program = "${dbStopScript}/bin/htr_db_stop"; };
          htr_db_schema  = { type = "app"; program = "${dbSchemaScript}/bin/htr_db_schema"; };
          htr_db_status  = { type = "app"; program = "${dbStatusScript}/bin/htr_db_status"; };

          # Venv y paquetes
          htr_setup_venv  = { type = "app"; program = "${setupVenvScript}/bin/htr_setup_venv"; };
          htr_pip_install = { type = "app"; program = "${pipInstallScript}/bin/htr_pip_install"; };
          htr_pip_remove  = { type = "app"; program = "${pipRemoveScript}/bin/htr_pip_remove"; };

          # Ingesta
          htr_register_collection  = { type = "app"; program = "${registerCollectionScript}/bin/htr_register_collection"; };
          htr_download_images      = { type = "app"; program = "${downloadImagesScript}/bin/htr_download_images"; };
          htr_register_ground_truth = { type = "app"; program = "${registerGroundTruthScript}/bin/htr_register_ground_truth"; };
          htr_register_model       = { type = "app"; program = "${registerModelScript}/bin/htr_register_model"; };
          htr_knowledge_base_rebuild = { type = "app"; program = "${knowledgeBaseRebuildScript}/bin/htr_knowledge_base_rebuild"; };

          # Anotaciones
          htr_export_for_annotation = { type = "app"; program = "${exportForAnnotationScript}/bin/htr_export_for_annotation"; };
          htr_sync_annotations      = { type = "app"; program = "${syncAnnotationsScript}/bin/htr_sync_annotations"; };

          # Observabilidad
          htr_operations_log  = { type = "app"; program = "${operationsLogScript}/bin/htr_operations_log"; };
          htr_pipeline_status = { type = "app"; program = "${pipelineStatusScript}/bin/htr_pipeline_status"; };

          # Slurm
          htr_slurm_typography_classification = { type = "app"; program = "${slurmTypographyScript}/bin/htr_slurm_typography_classification"; };
          htr_slurm_htr_transcription         = { type = "app"; program = "${slurmHtrTranscriptionScript}/bin/htr_slurm_htr_transcription"; };
          htr_slurm_historical_clean          = { type = "app"; program = "${slurmHistoricalCleanScript}/bin/htr_slurm_historical_clean"; };
          htr_slurm_clean_modern              = { type = "app"; program = "${slurmCleanModernScript}/bin/htr_slurm_clean_modern"; };

          # Menú
          htr_menu = { type = "app"; program = "${menuScript}/bin/htr_menu"; };
        };

        # ── Shell de desarrollo (nix develop) ────────────────────────
        devShells.default = pkgs.mkShell {
          name = "amoxcailab";

          buildInputs = [
            postgresql
            pythonEnv
            pkgs.gcc pkgs.gnumake pkgs.zlib pkgs.openssl pkgs.libffi
            pkgs.fzf pkgs.jq pkgs.git
            # Scripts htr_*
            dbInitScript dbStartScript dbStopScript dbSchemaScript dbStatusScript
            setupVenvScript pipInstallScript pipRemoveScript
            registerCollectionScript downloadImagesScript registerGroundTruthScript
            registerModelScript knowledgeBaseRebuildScript
            exportForAnnotationScript syncAnnotationsScript
            operationsLogScript pipelineStatusScript
            slurmTypographyScript slurmHtrTranscriptionScript
            slurmHistoricalCleanScript slurmCleanModernScript
            menuScript
          ];

          shellHook = ''
            # ── Variables de entorno ─────────────────────────────────
            ${dbEnvVars}

            # ── Activar venv si existe ───────────────────────────────
            if [ -f ".venv/bin/activate" ]; then
              source .venv/bin/activate
              echo "✓ Virtualenv .venv activado."
            fi

            # ── Arrancar PostgreSQL si el cluster está inicializado ──
            if [ -f "$HTR_PGDATA/PG_VERSION" ]; then
              if ! ${postgresql}/bin/pg_isready \
                   -h "$HTR_PGRUN" -p "$HTR_PGPORT" -q 2>/dev/null; then
                echo "▶ Iniciando PostgreSQL local..."
                ${postgresql}/bin/pg_ctl \
                  -D "$HTR_PGDATA" \
                  -l "$HTR_PGDATA/postgresql.log" \
                  start -w -t 10 2>/dev/null \
                  && echo "✓ PostgreSQL listo en puerto $HTR_PGPORT." \
                  || echo "⚠ PostgreSQL no pudo arrancar. Ver $HTR_PGDATA/postgresql.log"
              else
                echo "✓ PostgreSQL ya corriendo en puerto $HTR_PGPORT."
              fi
            else
              echo "⚠ Cluster PostgreSQL no inicializado. Ejecuta: htr_db_init"
            fi

            echo ""
            echo "╔══════════════════════════════════════════════╗"
            echo "║  AmoxcAILab HTR Pipeline — entorno listo     ║"
            echo "╠══════════════════════════════════════════════╣"
            echo "║  htr_menu                  menú interactivo  ║"
            echo "║  htr_db_init               inicializar BD    ║"
            echo "║  htr_db_start / _stop      arrancar/detener  ║"
            echo "║  htr_db_schema             aplicar schema    ║"
            echo "║  htr_pipeline_status       estado pipeline   ║"
            echo "║  htr_operations_log        log operaciones   ║"
            echo "║  htr_register_collection   alta colección    ║"
            echo "║  htr_download_images       importar imágs    ║"
            echo "║  htr_export_for_annotation exportar a JSON   ║"
            echo "║  htr_sync_annotations      sync anotaciones  ║"
            echo "║  htr_knowledge_base_rebuild rebuild RAG      ║"
            echo "╚══════════════════════════════════════════════╝"
            echo "  DB_URL      : $HTR_DB_URL"
            echo "  MODELS_DIR  : $HTR_MODELS_DIR"
            echo "  PIPELINE_DIR: $HTR_PIPELINE_DIR"
            echo ""
          '';
        };
      }
    );
}
