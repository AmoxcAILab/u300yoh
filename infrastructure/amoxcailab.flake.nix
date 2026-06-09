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
                -c "SELECT collection_id, collection_name, collection_type FROM public.v_collections ORDER BY collection_name;" \
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
            # nss_wrapper: crea entrada temporal en /etc/passwd para este UID
            # (necesario en entornos HPC/LDAP donde getpwuid(UID) falla)
            _PASSWD_FILE=$(mktemp)
            echo "$HTR_PGUSER:x:$(id -u):$(id -g):HTR Pipeline:$HOME:/bin/sh" > "$_PASSWD_FILE"
            NSS_WRAPPER_PASSWD="$_PASSWD_FILE" \
            NSS_WRAPPER_GROUP=/dev/null \
            LD_PRELOAD="${pkgs.nss_wrapper}/lib/libnss_wrapper.so" \
              ${postgresql}/bin/initdb \
                --pgdata="$HTR_PGDATA" \
                --auth=trust \
                --no-locale \
                --encoding=UTF8 \
                --username="$HTR_PGUSER"
            rm -f "$_PASSWD_FILE"
            echo "✓ Cluster inicializado."
          else
            echo "✓ Cluster ya existe. Saltando initdb."
          fi

          cat >> "$HTR_PGDATA/postgresql.conf" << 'PGCONF'

# HTR pipeline — configuración generada por htr_db_init
unix_socket_directories = 'HTR_PGRUN_PLACEHOLDER'
port = HTR_PGPORT_PLACEHOLDER
listen_addresses = '''
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
                ot.operation_type,
                o.status,
                to_char(o.logged_at, 'YYYY-MM-DD HH24:MI') AS logged_at,
                COALESCE(c.collaborator_name, '—') AS collaborator,
                COALESCE(o.slurm_job_id, o.transkribus_job_id, ''') AS job_id
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
        # EXPLORADOR DE DEPENDENCIAS PYTHON
        # ══════════════════════════════════════════════════════════

        requirementsScript = pkgs.writeShellScriptBin "htr_requirements" ''
          set -euo pipefail

          REQUIREMENTS="''${HTR_REQUIREMENTS:-requirements.txt}"
          VENV_DIR="''${HTR_VENV:-.venv}"

          if [ ! -f "$REQUIREMENTS" ]; then
            echo "✗ No se encontró $REQUIREMENTS"
            exit 1
          fi

          # Líneas que son paquetes reales (no comentarios, no vacías)
          _pkg_lines() {
            grep -E '^[A-Za-z]' "$REQUIREMENTS" || true
          }

          # Preview: pip show si el venv está activo, si no muestra la línea tal cual
          _preview_cmd() {
            local pkg
            pkg=$(echo "{}" | sed 's/[>=<!].*//' | tr -d ' ')
            if [ -f "$VENV_DIR/bin/pip" ]; then
              "$VENV_DIR/bin/pip" show "$pkg" 2>/dev/null \
                || echo "(no instalado en venv: $pkg)"
            else
              echo "(venv no disponible)"
              echo ""
              echo "Entrada en $REQUIREMENTS:"
              echo "  {}"
            fi
          }

          # Acción principal: modo de exploración
          ACCION="''${1:-}"

          case "$ACCION" in
            --install)
              shift
              if [ $# -gt 0 ]; then
                htr_pip_install "$@"
              else
                echo "▶ Paquete a instalar (ej: torch>=2.2):"
                read -r pkg
                [ -n "$pkg" ] && htr_pip_install "$pkg"
              fi
              ;;

            --remove)
              if [ ! -f "$VENV_DIR/bin/pip" ]; then
                echo "✗ Venv no disponible."
                exit 1
              fi
              pkg=$(_pkg_lines \
                | ${pkgs.fzf}/bin/fzf \
                    --prompt "Desinstalar > " \
                    --header "Selecciona paquete a eliminar (ESC para cancelar)" \
                    --preview "$(declare -f _preview_cmd); _preview_cmd" \
                    --preview-window right:50% \
                    --height 60% --border \
                    --select-1 || true)
              if [ -n "$pkg" ]; then
                pkg_name=$(echo "$pkg" | sed 's/[>=<!].*//' | tr -d ' ')
                htr_pip_remove "$pkg_name"
              fi
              ;;

            *)
              # Exploración: fzf sobre requirements.txt con preview de pip show
              selected=$(_pkg_lines \
                | ${pkgs.fzf}/bin/fzf \
                    --prompt "Dependencias > " \
                    --header "$(printf 'requirements.txt  |  [i] instalar  [d] desinstalar\n%s paquetes' "$(  _pkg_lines | wc -l | tr -d ' ')")" \
                    --preview "
                      pkg=\$(echo {} | sed 's/[>=<!].*//' | tr -d ' ')
                      if [ -f '$VENV_DIR/bin/pip' ]; then
                        '$VENV_DIR/bin/pip' show \"\$pkg\" 2>/dev/null \
                          || echo \"(no instalado en venv: \$pkg)\"
                      else
                        echo '(venv no disponible — ejecuta htr_setup_venv)'
                        echo '''
                        echo 'Entrada en requirements.txt:'
                        echo \"  {}\"
                      fi
                    " \
                    --preview-window right:50% \
                    --height 70% --border \
                    --bind "i:execute(htr_pip_install \$(echo {} | sed 's/[>=<!].*//' | tr -d ' '))+reload(_pkg_lines)" \
                    --bind "d:execute(htr_pip_remove \$(echo {} | sed 's/[>=<!].*//' | tr -d ' '))+reload(_pkg_lines)" \
                    --expect ctrl-n \
                  || true)

              # ctrl-n: instalar paquete nuevo
              if echo "$selected" | head -1 | grep -q "ctrl-n"; then
                echo "▶ Nombre del paquete nuevo:"
                read -r pkg
                [ -n "$pkg" ] && htr_pip_install "$pkg"
              fi
              ;;
          esac
        '';


        # ══════════════════════════════════════════════════════════
        # WRAPPERS PARA SCRIPTS DE IMAGEN
        # ══════════════════════════════════════════════════════════

        # Picker de imagen interactivo: collection → document → image
        # Usado por layoutAnalysisScript y preprocessImageScript.
        imagePicker = ''
          _pick_image_id() {
            local _prompt="''${1:-Imagen}"

            # 1. Seleccionar colección
            local _col_id
            _col_id=$(_pick_collection_id)
            [ -z "$_col_id" ] && return 1

            # 2. Seleccionar documento dentro de la colección
            local _doc_row
            _doc_row=$(${postgresql}/bin/psql \
              -h "$HTR_PGRUN" -p "$HTR_PGPORT" -d "$HTR_PGDB" \
              -tAF'|' \
              -c "SELECT document_id, document_name FROM public.documents
                  WHERE collection_id = '$_col_id' ORDER BY document_name;" \
              2>/dev/null \
              | ${pkgs.fzf}/bin/fzf \
                  --prompt "Documento > " --header "ID | nombre" \
                  --delimiter '|' --height 40% --border || true)
            local _doc_id
            _doc_id=$(echo "$_doc_row" | cut -d'|' -f1 | tr -d ' ')
            [ -z "$_doc_id" ] && return 1

            # 3. Seleccionar imagen dentro del documento
            local _img_row
            _img_row=$(${postgresql}/bin/psql \
              -h "$HTR_PGRUN" -p "$HTR_PGPORT" -d "$HTR_PGDB" \
              -tAF'|' \
              -c "SELECT i.image_id, i.image_filename, it.image_type,
                         COALESCE(i.page_number::text, '—') AS page
                  FROM public.images i
                  JOIN public.image_types it USING (image_type_id)
                  WHERE i.document_id = '$_doc_id'
                  ORDER BY i.page_number NULLS LAST, i.image_filename;" \
              2>/dev/null \
              | ${pkgs.fzf}/bin/fzf \
                  --prompt "$_prompt > " \
                  --header "image_id | archivo | tipo | página" \
                  --delimiter '|' --height 50% --border \
                  --preview "
                    ${postgresql}/bin/psql \
                      -h '$HTR_PGRUN' -p '$HTR_PGPORT' -d '$HTR_PGDB' \
                      -c \"SELECT image_filename, image_path, image_type_id,
                                  page_number, calligraphy_type_id, calligraphy_confidence
                           FROM public.images WHERE image_id = '{1}';\" 2>/dev/null
                  " \
                  --preview-window right:45% \
              || true)
            echo "$_img_row" | cut -d'|' -f1 | tr -d ' '
          }
        '';

        layoutAnalysisScript = pkgs.writeShellScriptBin "htr_layout_analysis" ''
          set -euo pipefail
          ${dbEnvVars}
          ${venvCheck}
          ${dbCheck}
          ${fzfCollectionPicker}
          ${imagePicker}

          IMAGE_ID="''${1:-}"
          if [ -z "$IMAGE_ID" ]; then
            IMAGE_ID=$(_pick_image_id "Layout analysis")
          fi
          if [ -z "$IMAGE_ID" ]; then
            echo "✗ No se seleccionó imagen."
            exit 1
          fi

          echo "▶ Enviando imagen $IMAGE_ID a layout analysis (Transkribus)..."
          cd "$HTR_PIPELINE_DIR"
          "$PYTHON" data_ingestion/send_to_layout_analysis.py --image-id "$IMAGE_ID" "$@"
        '';

        preprocessImageScript = pkgs.writeShellScriptBin "htr_preprocess_image" ''
          set -euo pipefail
          ${dbEnvVars}
          ${venvCheck}
          ${dbCheck}
          ${fzfCollectionPicker}
          ${imagePicker}

          IMAGE_ID="''${1:-}"
          if [ -z "$IMAGE_ID" ]; then
            IMAGE_ID=$(_pick_image_id "Pre-procesar")
          fi
          if [ -z "$IMAGE_ID" ]; then
            echo "✗ No se seleccionó imagen."
            exit 1
          fi

          echo "▶ Pre-procesando imagen $IMAGE_ID (CLAHE)..."
          cd "$HTR_PIPELINE_DIR"
          "$PYTHON" data_ingestion/image_pre_processing.py --image-id "$IMAGE_ID" "$@"
        '';


        # ══════════════════════════════════════════════════════════
        # MENÚ INTERACTIVO PRINCIPAL
        # ══════════════════════════════════════════════════════════

        menuScript = pkgs.writeShellScriptBin "htr_menu" ''
          set -euo pipefail
          ${dbEnvVars}
          ${fzfCollectionPicker}
          ${imagePicker}

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

          # ══════════════════════════════════════════════════════
          # SUBMENÚS
          # ══════════════════════════════════════════════════════

          # ── Colecciones ──────────────────────────────────────────
          _menu_colecciones() {
            local opcion
            opcion=$(printf \
              "ver_colecciones\nregistrar\neliminar\nvolver" \
              | ${pkgs.fzf}/bin/fzf \
                  --prompt "Colecciones > " \
                  --header "$(_db_status_line)" \
                  --height 10 --border)
            case "$opcion" in
              ver_colecciones)
                ${postgresql}/bin/psql \
                  -h "$HTR_PGRUN" -p "$HTR_PGPORT" -d "$HTR_PGDB" \
                  -tAF'|' \
                  -c "SELECT collection_id, collection_name, collection_type,
                             collection_status,
                             COALESCE(archival_institution_name,'—'),
                             COALESCE(collection_path,'—'),
                             COALESCE(collection_url,'—')
                      FROM public.v_collections
                      ORDER BY collection_type, collection_name;" \
                2>/dev/null \
                | ${pkgs.fzf}/bin/fzf \
                    --prompt "Colecciones > " \
                    --header "nombre | tipo | estado | institución" \
                    --delimiter '|' \
                    --with-nth '2..5' \
                    --height 80% --border \
                    --preview "echo 'Nombre:      {2}'; echo 'Tipo:        {3}'; echo 'Estado:      {4}'; echo 'Institución: {5}'; echo 'Ruta:        {6}'; echo 'URL:         {7}'" \
                    --preview-window 'right:45%:wrap' \
                || true
                ;;
              registrar)
                METADATA_DIR="$HTR_PIPELINE_DIR/data_ingestion/metadata"
                if [ ! -d "$METADATA_DIR" ]; then
                  echo "✗ Directorio no encontrado: $METADATA_DIR"
                  return
                fi
                metadata_file=$(find "$METADATA_DIR" -maxdepth 2 -name "*.metadata" \
                  | sed "s|$HTR_PIPELINE_DIR/||" \
                  | sort \
                  | ${pkgs.fzf}/bin/fzf \
                      --prompt "Colección > " \
                      --header "Selecciona archivo .metadata (ESC para cancelar)" \
                      --preview "cat '$HTR_PIPELINE_DIR/{}' 2>/dev/null" \
                      --preview-window right:50% \
                      --height 60% --border \
                  || true)
                if [ -z "$metadata_file" ]; then
                  echo "✗ No se seleccionó ningún archivo."
                  return
                fi
                htr_register_collection --collection-metadata "$HTR_PIPELINE_DIR/$metadata_file"
                ;;
              eliminar)
                COL_ID=$(_pick_collection_id)
                [ -z "$COL_ID" ] && return
                COL_NAME=$(${postgresql}/bin/psql \
                  -h "$HTR_PGRUN" -p "$HTR_PGPORT" -d "$HTR_PGDB" \
                  -tAc "SELECT collection_name FROM public.collections WHERE collection_id = '$COL_ID'")
                echo "⚠ Vas a eliminar '$COL_NAME' y todos sus documentos y notas."
                echo "  Escribe el nombre de la colección para confirmar:"
                read -r confirm
                if [ "$confirm" = "$COL_NAME" ]; then
                  ${postgresql}/bin/psql \
                    -h "$HTR_PGRUN" -p "$HTR_PGPORT" -d "$HTR_PGDB" \
                    -v ON_ERROR_STOP=1 << DELSQL
DELETE FROM public.notes_operations
  WHERE note_id IN (
    SELECT nd.note_id FROM public.notes_documents nd
    JOIN public.documents d USING (document_id)
    WHERE d.collection_id = '$COL_ID');
DELETE FROM public.notes_documents
  WHERE document_id IN (
    SELECT document_id FROM public.documents WHERE collection_id = '$COL_ID');
DELETE FROM public.notes_collections WHERE collection_id = '$COL_ID';
DELETE FROM public.documents_operations
  WHERE document_id IN (
    SELECT document_id FROM public.documents WHERE collection_id = '$COL_ID');
DELETE FROM public.collections_operations WHERE collection_id = '$COL_ID';
DELETE FROM public.documents WHERE collection_id = '$COL_ID';
DELETE FROM public.collections WHERE collection_id = '$COL_ID';
DELSQL
                  echo "✓ Colección '$COL_NAME' eliminada."
                else
                  echo "✗ Nombre incorrecto. Operación cancelada."
                fi
                ;;
            esac
          }

          # ── Documentos ───────────────────────────────────────────
          _menu_documentos() {
            local opcion
            opcion=$(printf "ver_documentos\nvolver" \
              | ${pkgs.fzf}/bin/fzf \
                  --prompt "Documentos > " \
                  --header "$(_db_status_line)" \
                  --height 8 --border)
            case "$opcion" in
              ver_documentos)
                COL_ID=$(_pick_collection_id)
                [ -z "$COL_ID" ] && return
                COL_NAME=$(${postgresql}/bin/psql \
                  -h "$HTR_PGRUN" -p "$HTR_PGPORT" -d "$HTR_PGDB" \
                  -tAc "SELECT collection_name FROM public.collections WHERE collection_id = '$COL_ID'")
                ${postgresql}/bin/psql \
                  -h "$HTR_PGRUN" -p "$HTR_PGPORT" -d "$HTR_PGDB" \
                  -tAF'|' \
                  -c "SELECT d.document_id, d.document_name,
                             COALESCE(d.document_Expediente,'—'),
                             COALESCE(d.document_Fecha_creacion,'—'),
                             ds.document_status,
                             COALESCE(d.document_Fondo,'—'),
                             COALESCE(d.document_Volumen,'—'),
                             COALESCE(d.document_Lugar_creacion,'—'),
                             COALESCE(d.document_Soporte,'—'),
                             COALESCE(d.document_Descripcion,'—')
                      FROM public.documents d
                      JOIN public.document_statuses ds USING (document_status_id)
                      WHERE d.collection_id = '$COL_ID'
                      ORDER BY d.document_name;" \
                2>/dev/null \
                | ${pkgs.fzf}/bin/fzf \
                    --prompt "$COL_NAME > " \
                    --header "nombre | expediente | fecha | estado" \
                    --delimiter '|' \
                    --with-nth '2..5' \
                    --height 80% --border \
                    --preview "echo 'Nombre:     {2}'; echo 'Expediente: {3}'; echo 'Fecha:      {4}'; echo 'Estado:     {5}'; echo 'Fondo:      {6}'; echo 'Volumen:    {7}'; echo 'Lugar:      {8}'; echo 'Soporte:    {9}'; echo ''; echo 'Descripción:'; echo '{10}'" \
                    --preview-window 'right:45%:wrap' \
                || true
                ;;
            esac
          }

          # ── Imágenes ─────────────────────────────────────────────
          _menu_imagenes() {
            local opcion
            opcion=$(printf \
              "ver_imagenes\nenviar_a_clasificador\npre_procesar\nregistrar\ndescargar\nvolver" \
              | ${pkgs.fzf}/bin/fzf \
                  --prompt "Imágenes > " \
                  --header "$(_db_status_line)" \
                  --height 12 --border)
            case "$opcion" in
              ver_imagenes)
                COL_ID=$(_pick_collection_id)
                [ -z "$COL_ID" ] && return
                ${postgresql}/bin/psql \
                  -h "$HTR_PGRUN" -p "$HTR_PGPORT" -d "$HTR_PGDB" \
                  -tAF'|' \
                  -c "SELECT i.image_id, d.document_name, i.image_filename,
                             it.image_type,
                             COALESCE(i.page_number::text,'—') AS page,
                             COALESCE(ct.calligraphy_type,'—') AS calligrafia
                      FROM public.images i
                      JOIN public.image_types it USING (image_type_id)
                      JOIN public.documents d USING (document_id)
                      LEFT JOIN public.calligraphy_types ct USING (calligraphy_type_id)
                      WHERE d.collection_id = '$COL_ID'
                      ORDER BY d.document_name, i.page_number NULLS LAST, i.image_filename;" \
                2>/dev/null \
                | ${pkgs.fzf}/bin/fzf \
                    --prompt "Imágenes > " \
                    --header "image_id | documento | archivo | tipo | pág | caligrafía" \
                    --delimiter '|' --height 80% --border \
                    --preview "
                      ${postgresql}/bin/psql \
                        -h '$HTR_PGRUN' -p '$HTR_PGPORT' -d '$HTR_PGDB' \
                        -c \"SELECT image_filename, image_path, image_type_id,
                                    page_number, calligraphy_type_id, calligraphy_confidence
                             FROM public.images WHERE image_id = '{1}';\" 2>/dev/null
                    " \
                    --preview-window right:45% \
                || true
                ;;
              enviar_a_clasificador)
                echo "▶ Archivo batch (image_ids, uno por línea):"
                read -r batch
                htr_slurm_typography_classification "$batch"
                ;;
              pre_procesar)
                htr_preprocess_image
                ;;
              registrar)
                echo "TODO: registrar imágenes locales en disco sin descargar"
                ;;
              descargar)
                htr_download_images
                ;;
            esac
          }

          # ── HTR ──────────────────────────────────────────────────
          _menu_htr() {
            local opcion
            opcion=$(printf \
              "ver_archivos_htr\nenviar_a_transcripcion\nenviar_a_layout_analysis\nvolver" \
              | ${pkgs.fzf}/bin/fzf \
                  --prompt "HTR > " \
                  --header "$(_db_status_line)" \
                  --height 10 --border)
            case "$opcion" in
              ver_archivos_htr)
                COL_ID=$(_pick_collection_id)
                [ -z "$COL_ID" ] && return
                ${postgresql}/bin/psql \
                  -h "$HTR_PGRUN" -p "$HTR_PGPORT" -d "$HTR_PGDB" \
                  -tAF'|' \
                  -c "SELECT h.htr_id, d.document_name, i.image_filename,
                             h.htr_filename,
                             COALESCE(ct.calligraphy_type,'—') AS calligrafia
                      FROM public.htr h
                      JOIN public.images i USING (image_id)
                      JOIN public.documents d USING (document_id)
                      LEFT JOIN public.calligraphy_types ct USING (calligraphy_type_id)
                      WHERE d.collection_id = '$COL_ID'
                      ORDER BY d.document_name, i.page_number NULLS LAST;" \
                2>/dev/null \
                | ${pkgs.fzf}/bin/fzf \
                    --prompt "HTR > " \
                    --header "htr_id | documento | imagen | archivo HTR | caligrafía" \
                    --delimiter '|' --height 80% --border \
                    --preview "
                      ${postgresql}/bin/psql \
                        -h '$HTR_PGRUN' -p '$HTR_PGPORT' -d '$HTR_PGDB' \
                        -c \"SELECT h.htr_filename, h.htr_path, h.transkribus_model_id
                             FROM public.htr h WHERE h.htr_id = '{1}';\" 2>/dev/null
                    " \
                    --preview-window right:45% \
                || true
                ;;
              enviar_a_transcripcion)
                echo "▶ Archivo batch (image_ids, uno por línea):"
                read -r batch
                htr_slurm_htr_transcription "$batch"
                ;;
              enviar_a_layout_analysis)
                htr_layout_analysis
                ;;
            esac
          }

          # ── Ground Truth ─────────────────────────────────────────
          _menu_ground_truth() {
            local opcion
            opcion=$(printf \
              "ver_ground_truth\nregistrar_ground_truth\nvolver" \
              | ${pkgs.fzf}/bin/fzf \
                  --prompt "Ground Truth > " \
                  --header "$(_db_status_line)" \
                  --height 9 --border)
            case "$opcion" in
              ver_ground_truth)
                COL_ID=$(_pick_collection_id)
                [ -z "$COL_ID" ] && return
                ${postgresql}/bin/psql \
                  -h "$HTR_PGRUN" -p "$HTR_PGPORT" -d "$HTR_PGDB" \
                  -tAF'|' \
                  -c "SELECT gt.ground_truth_id, d.document_name,
                             i.image_filename, gt.ground_truth_filename
                      FROM public.ground_truth gt
                      JOIN public.htr h USING (htr_id)
                      JOIN public.images i USING (image_id)
                      JOIN public.documents d USING (document_id)
                      WHERE d.collection_id = '$COL_ID'
                      ORDER BY d.document_name, i.page_number NULLS LAST;" \
                2>/dev/null \
                | ${pkgs.fzf}/bin/fzf \
                    --prompt "Ground Truth > " \
                    --header "gt_id | documento | imagen | archivo GT" \
                    --delimiter '|' --height 80% --border \
                    --preview "
                      ${postgresql}/bin/psql \
                        -h '$HTR_PGRUN' -p '$HTR_PGPORT' -d '$HTR_PGDB' \
                        -c \"SELECT gt.ground_truth_filename, gt.ground_truth_path
                             FROM public.ground_truth gt WHERE gt.ground_truth_id = '{1}';\" 2>/dev/null
                    " \
                    --preview-window right:45% \
                || true
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
            esac
          }

          # ── Limpieza ─────────────────────────────────────────────
          _menu_limpieza() {
            local opcion
            opcion=$(printf \
              "listar_versiones_limpias\nenviar_a_limpieza\nexportar_para_anotacion\nimportar_anotaciones\nvolver" \
              | ${pkgs.fzf}/bin/fzf \
                  --prompt "Limpieza > " \
                  --header "$(_db_status_line)" \
                  --height 11 --border)
            case "$opcion" in
              listar_versiones_limpias)
                COL_ID=$(_pick_collection_id)
                [ -z "$COL_ID" ] && return
                ${postgresql}/bin/psql \
                  -h "$HTR_PGRUN" -p "$HTR_PGPORT" -d "$HTR_PGDB" \
                  -tAF'|' \
                  -c "SELECT hc.hist_clean_id, d.document_name,
                             i.image_filename, hc.hist_clean_filename
                      FROM public.hist_clean hc
                      JOIN public.htr h USING (htr_id)
                      JOIN public.images i USING (image_id)
                      JOIN public.documents d USING (document_id)
                      WHERE d.collection_id = '$COL_ID'
                      ORDER BY d.document_name, i.page_number NULLS LAST;" \
                2>/dev/null \
                | ${pkgs.fzf}/bin/fzf \
                    --prompt "Hist. clean > " \
                    --header "hist_clean_id | documento | imagen | archivo" \
                    --delimiter '|' --height 80% --border \
                    --preview "
                      cat '{4}' 2>/dev/null || echo '(archivo no disponible localmente)'
                    " \
                    --preview-window right:50% \
                || true
                ;;
              enviar_a_limpieza)
                echo "▶ Archivo batch (htr_ids, uno por línea):"
                read -r batch
                htr_slurm_historical_clean "$batch"
                ;;
              exportar_para_anotacion)
                COL_ID=$(_pick_collection_id)
                [ -z "$COL_ID" ] && return
                htr_export_for_annotation --collection-id "$COL_ID"
                ;;
              importar_anotaciones)
                echo "▶ Directorio de anotaciones:"
                read -r ann_dir
                htr_sync_annotations --annotations-dir "$ann_dir"
                ;;
            esac
          }

          # ── Modernización ────────────────────────────────────────
          _menu_modernizacion() {
            local opcion
            opcion=$(printf \
              "listar_modernizaciones\nenviar_a_modernizacion\nexportar_para_anotacion\nimportar_anotaciones\nvolver" \
              | ${pkgs.fzf}/bin/fzf \
                  --prompt "Modernización > " \
                  --header "$(_db_status_line)" \
                  --height 11 --border)
            case "$opcion" in
              listar_modernizaciones)
                COL_ID=$(_pick_collection_id)
                [ -z "$COL_ID" ] && return
                ${postgresql}/bin/psql \
                  -h "$HTR_PGRUN" -p "$HTR_PGPORT" -d "$HTR_PGDB" \
                  -tAF'|' \
                  -c "SELECT cm.clean_modern_id, d.document_name,
                             i.image_filename, cm.clean_modern_filename
                      FROM public.clean_modern cm
                      JOIN public.hist_clean hc USING (hist_clean_id)
                      JOIN public.htr h USING (htr_id)
                      JOIN public.images i USING (image_id)
                      JOIN public.documents d USING (document_id)
                      WHERE d.collection_id = '$COL_ID'
                      ORDER BY d.document_name, i.page_number NULLS LAST;" \
                2>/dev/null \
                | ${pkgs.fzf}/bin/fzf \
                    --prompt "Clean modern > " \
                    --header "clean_modern_id | documento | imagen | archivo" \
                    --delimiter '|' --height 80% --border \
                    --preview "
                      cat '{4}' 2>/dev/null || echo '(archivo no disponible localmente)'
                    " \
                    --preview-window right:50% \
                || true
                ;;
              enviar_a_modernizacion)
                echo "▶ Archivo batch (htr_ids, uno por línea):"
                read -r batch
                htr_slurm_clean_modern "$batch"
                ;;
              exportar_para_anotacion)
                COL_ID=$(_pick_collection_id)
                [ -z "$COL_ID" ] && return
                htr_export_for_annotation --collection-id "$COL_ID"
                ;;
              importar_anotaciones)
                echo "▶ Directorio de anotaciones:"
                read -r ann_dir
                htr_sync_annotations --annotations-dir "$ann_dir"
                ;;
            esac
          }

          # ── Notas ────────────────────────────────────────────────
          _menu_notas() {
            local opcion
            opcion=$(printf "listar_notas_por_coleccion\nvolver" \
              | ${pkgs.fzf}/bin/fzf \
                  --prompt "Notas > " \
                  --header "$(_db_status_line)" \
                  --height 8 --border)
            case "$opcion" in
              listar_notas_por_coleccion)
                COL_ID=$(_pick_collection_id)
                [ -z "$COL_ID" ] && return
                ${postgresql}/bin/psql \
                  -h "$HTR_PGRUN" -p "$HTR_PGPORT" -d "$HTR_PGDB" \
                  -tAF'|' \
                  -c "SELECT n.note_id, d.document_name, n.note
                      FROM public.notes n
                      JOIN public.notes_documents nd USING (note_id)
                      JOIN public.documents d USING (document_id)
                      WHERE d.collection_id = '$COL_ID'
                      ORDER BY 2, 1;" \
                2>/dev/null \
                | ${pkgs.fzf}/bin/fzf \
                    --prompt "Notas > " \
                    --header "note_id | documento | nota" \
                    --delimiter '|' --height 80% --border \
                    --preview "echo '{3}'" \
                    --preview-window bottom:40%:wrap \
                || true
                ;;
            esac
          }

          # ── Modelos ──────────────────────────────────────────────
          _menu_modelos() {
            local opcion
            opcion=$(printf \
              "ver_modelos\nmodificar_parametros\nregistrar_modelo\nvolver" \
              | ${pkgs.fzf}/bin/fzf \
                  --prompt "Modelos > " \
                  --header "$(_db_status_line)" \
                  --height 10 --border)
            case "$opcion" in
              ver_modelos)
                ${postgresql}/bin/psql \
                  -h "$HTR_PGRUN" -p "$HTR_PGPORT" -d "$HTR_PGDB" \
                  -c "SELECT model_id, model_name, model_type, model_version,
                             model_url, model_local_path,
                             model_parameter_1, model_parameter_n
                      FROM public.models ORDER BY model_id;" \
                2>/dev/null || echo "BD no disponible."
                ;;
              modificar_parametros)
                if ! _db_online; then echo "✗ BD no disponible."; return; fi
                MODEL_ID=$(${postgresql}/bin/psql \
                  -h "$HTR_PGRUN" -p "$HTR_PGPORT" -d "$HTR_PGDB" \
                  -tAF'|' \
                  -c "SELECT model_id, model_name, model_type FROM public.models ORDER BY model_name;" \
                2>/dev/null \
                | ${pkgs.fzf}/bin/fzf \
                    --prompt "Modelo > " --header "ID | nombre | tipo" \
                    --delimiter '|' --height 40% --border \
                | cut -d'|' -f1 | tr -d ' ' || true)
                [ -z "$MODEL_ID" ] && return
                echo "▶ Nuevo model_url       (Enter para mantener):"
                read -r new_url
                echo "▶ Nueva model_version   (Enter para mantener):"
                read -r new_ver
                echo "▶ Nuevo model_local_path (Enter para mantener):"
                read -r new_path
                echo "▶ Nuevo model_parameter_1 (Enter para mantener):"
                read -r new_p1
                echo "▶ Nuevo model_parameter_n (Enter para mantener):"
                read -r new_pn
                [ -n "$new_url" ]  && ${postgresql}/bin/psql -h "$HTR_PGRUN" -p "$HTR_PGPORT" -d "$HTR_PGDB" \
                  -c "UPDATE public.models SET model_url = '$new_url' WHERE model_id = '$MODEL_ID';" 2>/dev/null
                [ -n "$new_ver" ]  && ${postgresql}/bin/psql -h "$HTR_PGRUN" -p "$HTR_PGPORT" -d "$HTR_PGDB" \
                  -c "UPDATE public.models SET model_version = '$new_ver' WHERE model_id = '$MODEL_ID';" 2>/dev/null
                [ -n "$new_path" ] && ${postgresql}/bin/psql -h "$HTR_PGRUN" -p "$HTR_PGPORT" -d "$HTR_PGDB" \
                  -c "UPDATE public.models SET model_local_path = '$new_path' WHERE model_id = '$MODEL_ID';" 2>/dev/null
                [ -n "$new_p1" ]   && ${postgresql}/bin/psql -h "$HTR_PGRUN" -p "$HTR_PGPORT" -d "$HTR_PGDB" \
                  -c "UPDATE public.models SET model_parameter_1 = '$new_p1' WHERE model_id = '$MODEL_ID';" 2>/dev/null
                [ -n "$new_pn" ]   && ${postgresql}/bin/psql -h "$HTR_PGRUN" -p "$HTR_PGPORT" -d "$HTR_PGDB" \
                  -c "UPDATE public.models SET model_parameter_n = '$new_pn' WHERE model_id = '$MODEL_ID';" 2>/dev/null
                echo "✓ Modelo $MODEL_ID actualizado."
                ;;
              registrar_modelo)
                echo "▶ Nombre del modelo:"
                read -r mname
                echo "▶ Ruta local del modelo:"
                read -r mpath
                echo "▶ Tipo (htr / typography / layout):"
                read -r mtype
                htr_register_model "$mname" "$mpath" "''${mtype:-htr}"
                ;;
            esac
          }

          # ── Base de conocimiento ─────────────────────────────────
          _menu_base_conocimiento() {
            local opcion
            opcion=$(printf \
              "ver_diccionarios\nver_abreviaturas\nregistrar_abreviaturas\nver_analisis_descriptivos\nregistrar_analisis_descriptivos\nreconstruir_base_de_conocimiento\nvolver" \
              | ${pkgs.fzf}/bin/fzf \
                  --prompt "Base de conocimiento > " \
                  --header "$(_db_status_line)" \
                  --height 13 --border)
            case "$opcion" in
              ver_diccionarios)
                local sub
                sub=$(printf "rag_knowledge_base\nabreviaturas_y_expansiones\nvolver" \
                  | ${pkgs.fzf}/bin/fzf \
                      --prompt "Diccionarios > " \
                      --header "$(_db_status_line)" \
                      --height 9 --border)
                case "$sub" in
                  rag_knowledge_base)
                    ${postgresql}/bin/psql \
                      -h "$HTR_PGRUN" -p "$HTR_PGPORT" -d "$HTR_PGDB" \
                      -c "SELECT knowledge_base_type,
                                 COUNT(*) AS total,
                                 COUNT(*) FILTER (WHERE verified) AS verificados
                          FROM rag.knowledge_base
                          GROUP BY knowledge_base_type
                          ORDER BY knowledge_base_type;" 2>/dev/null \
                    || echo "(tabla rag.knowledge_base no disponible)"
                    ;;
                  abreviaturas_y_expansiones)
                    ${postgresql}/bin/psql \
                      -h "$HTR_PGRUN" -p "$HTR_PGPORT" -d "$HTR_PGDB" \
                      -tAF'|' \
                      -c "SELECT a.abbreviation_id, a.abbreviation,
                                 COALESCE(e.expansion,'—'), et.expansion_type
                          FROM public.abbreviations a
                          LEFT JOIN public.abbreviations_expansions ae USING (abbreviation_id)
                          LEFT JOIN public.expansions e USING (expansion_id)
                          LEFT JOIN public.expansion_type et USING (expansion_type_id)
                          ORDER BY a.abbreviation;" \
                    2>/dev/null \
                    | ${pkgs.fzf}/bin/fzf \
                        --prompt "Abreviaturas > " \
                        --header "id | abreviatura | expansión | tipo" \
                        --delimiter '|' --height 80% --border \
                    || true
                    ;;
                esac
                ;;
              ver_abreviaturas)
                COL_ID=$(_pick_collection_id)
                [ -z "$COL_ID" ] && return
                ${postgresql}/bin/psql \
                  -h "$HTR_PGRUN" -p "$HTR_PGPORT" -d "$HTR_PGDB" \
                  -tAF'|' \
                  -c "SELECT a.abbreviation_id, a.abbreviation,
                             COALESCE(e.expansion,'—') AS expansion,
                             d.document_name
                      FROM public.abbreviations a
                      JOIN public.htr_abbreviations ha USING (abbreviation_id)
                      JOIN public.htr h USING (htr_id)
                      JOIN public.images i USING (image_id)
                      JOIN public.documents d USING (document_id)
                      LEFT JOIN public.abbreviations_expansions ae USING (abbreviation_id)
                      LEFT JOIN public.expansions e USING (expansion_id)
                      WHERE d.collection_id = '$COL_ID'
                      ORDER BY d.document_name, a.abbreviation;" \
                2>/dev/null \
                | ${pkgs.fzf}/bin/fzf \
                    --prompt "Abreviaturas > " \
                    --header "id | abreviatura | expansión | documento" \
                    --delimiter '|' --height 80% --border \
                || true
                ;;
              registrar_abreviaturas)
                echo "▶ Directorio de anotaciones JSON:"
                read -r ann_dir
                [ -z "$ann_dir" ] && return
                htr_sync_annotations --annotations-dir "$ann_dir" --no-kb-rebuild
                ;;
              ver_analisis_descriptivos)
                COL_ID=$(_pick_collection_id)
                [ -z "$COL_ID" ] && return
                ${postgresql}/bin/psql \
                  -h "$HTR_PGRUN" -p "$HTR_PGPORT" -d "$HTR_PGDB" \
                  -c "SELECT at.analysis_type, d.document_name,
                             da.cer, da.wer, da.bleu, da.chrf_pp,
                             da.n_errors, da.analyzed_at
                      FROM public.descriptive_analysis da
                      JOIN public.analysis_types at USING (analysis_type_id)
                      JOIN public.documents d USING (document_id)
                      WHERE d.collection_id = '$COL_ID'
                      ORDER BY d.document_name, da.analyzed_at DESC;" \
                2>/dev/null || echo "(sin análisis disponibles)"
                ;;
              registrar_analisis_descriptivos)
                echo "▶ Directorio de anotaciones JSON:"
                read -r ann_dir
                [ -z "$ann_dir" ] && return
                htr_sync_annotations --annotations-dir "$ann_dir"
                ;;
              reconstruir_base_de_conocimiento)
                htr_knowledge_base_rebuild
                ;;
            esac
          }

          # ── Operaciones ──────────────────────────────────────────
          _menu_operaciones() {
            htr_operations_log
          }

          # ── Infraestructura ──────────────────────────────────────
          _menu_infraestructura() {
            local opcion
            opcion=$(printf "paquetes_python\nbase_de_datos\nvolver" \
              | ${pkgs.fzf}/bin/fzf \
                  --prompt "Infraestructura > " \
                  --header "$(_db_status_line)" \
                  --height 9 --border)
            case "$opcion" in
              paquetes_python) _menu_python_packages ;;
              base_de_datos)   _menu_base_de_datos ;;
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
              iniciar_bd)     htr_db_start ;;
              detener_bd)     htr_db_stop ;;
              aplicar_schema) htr_db_schema ;;
              estado_bd)      htr_db_status ;;
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

          _menu_python_packages() {
            local opcion
            opcion=$(printf \
              "explorar_requirements\ninstalar_paquete\ndesinstalar_paquete\nsetup_venv\nvolver" \
              | ${pkgs.fzf}/bin/fzf \
                  --prompt "Python packages > " \
                  --header "$(printf 'Venv: %s\nReqs: %s' "''${HTR_VENV:-.venv}" "''${HTR_REQUIREMENTS:-requirements.txt}")" \
                  --height 12 --border)
            case "$opcion" in
              explorar_requirements)  htr_requirements ;;
              instalar_paquete)       htr_requirements --install ;;
              desinstalar_paquete)    htr_requirements --remove ;;
              setup_venv)             htr_setup_venv ;;
            esac
          }

          # ── Bucle principal del menú ─────────────────────────────
          while true; do
            OPCION=$(printf \
              "colecciones\ndocumentos\nimágenes\nhtr\nground_truth\nlimpieza\nmodernización\nbase_de_conocimiento\nmodelos\nnotas\noperaciones\ninfrastructura\nsalir" \
              | ${pkgs.fzf}/bin/fzf \
                  --prompt "AmoxcAILab > " \
                  --header "$(printf '═══ AmoxcAILab HTR Pipeline ═══\n%s' "$(_db_status_line)")" \
                  --height 19 \
                  --border \
                  --no-info \
                  --cycle) || break

            case "$OPCION" in
              colecciones)            _menu_colecciones ;;
              documentos)             _menu_documentos ;;
              "imágenes")             _menu_imagenes ;;
              htr)                    _menu_htr ;;
              ground_truth)           _menu_ground_truth ;;
              limpieza)               _menu_limpieza ;;
              "modernización")        _menu_modernizacion ;;
              base_de_conocimiento)   _menu_base_conocimiento ;;
              modelos)                _menu_modelos ;;
              notas)                  _menu_notas ;;
              operaciones)            _menu_operaciones ;;
              infrastructura)         _menu_infraestructura ;;
              salir|"")               break ;;
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
          htr_requirements = { type = "app"; program = "${requirementsScript}/bin/htr_requirements"; };

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

          # Wrappers nuevos
          htr_layout_analysis  = { type = "app"; program = "${layoutAnalysisScript}/bin/htr_layout_analysis"; };
          htr_preprocess_image = { type = "app"; program = "${preprocessImageScript}/bin/htr_preprocess_image"; };

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
            pkgs.fzf pkgs.jq pkgs.git pkgs.nss_wrapper
            # Scripts htr_*
            dbInitScript dbStartScript dbStopScript dbSchemaScript dbStatusScript
            setupVenvScript pipInstallScript pipRemoveScript requirementsScript
            registerCollectionScript downloadImagesScript registerGroundTruthScript
            registerModelScript knowledgeBaseRebuildScript
            exportForAnnotationScript syncAnnotationsScript
            operationsLogScript pipelineStatusScript
            slurmTypographyScript slurmHtrTranscriptionScript
            slurmHistoricalCleanScript slurmCleanModernScript
            layoutAnalysisScript preprocessImageScript
            menuScript
          ];

          shellHook = ''
            # ── Variables de entorno ─────────────────────────────────
            ${dbEnvVars}

            # ── PYTHONPATH: raíz del proyecto para imports de database.* ──
            export PYTHONPATH="''${HTR_PIPELINE_DIR}''${PYTHONPATH:+:$PYTHONPATH}"

            # ── LD_LIBRARY_PATH: librerías Nix para extensiones C del venv ──
            export LD_LIBRARY_PATH="${pkgs.zlib}/lib:${pkgs.openssl.out}/lib:${pkgs.libffi}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

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
