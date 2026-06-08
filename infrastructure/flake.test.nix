{
  description = "HTR cleaning pipeline — Schmidt Sciences cluster";

  # ──────────────────────────────────────────────────────────
  # INPUTS
  # nixos-24.11 es el canal estable más reciente con Python 3.11,
  # PostgreSQL 15 y pgvector. Fijar el hash garantiza reproducibilidad
  # entre miembros del equipo y entre jobs de Slurm.
  # ──────────────────────────────────────────────────────────
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

    # flake-utils para múltiples sistemas
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = false;
        };

        # ── PostgreSQL 15 con extensión pgvector ───────────────
        postgresql = pkgs.postgresql_15.withPackages (ps: [ ps.pgvector ]);

        # ── Python 3.11 con dependencias del sistema ───────────
        python = pkgs.python311;

        # ── Paquetes Python en el entorno Nix ──────────────────
        # Usamos nixpkgs para las librerías con extensiones C nativas.
        # Las versiones exactas del requirements.txt se instalan
        # luego en el venv (ver app setup-venv / shellHook).
        pythonEnv = python.withPackages (ps: with ps; [
          pip
          virtualenv
          # dependencias nativas críticas (compiladas en Nix)
          numpy
          scipy
          scikit-learn
          pandas
          matplotlib
          pillow
          # puras Python (rápidas de instalar vía pip también)
          requests
          tqdm
          regex
          six
          packaging
          python-dateutil
          # driver PostgreSQL
          psycopg2
        ]);

        # ── Variables de entorno para la BD local ──────────────
        # Directorio sin root. El socket Unix vive en un dir
        # dentro de $HOME para evitar necesitar /var/run.
        dbEnvVars = ''
          export HTR_PGDATA="''${HTR_PGDATA:-$HOME/.local/share/htr-pipeline/pgdata}"
          export HTR_PGRUN="''${HTR_PGRUN:-$HOME/.local/share/htr-pipeline/run}"
          export HTR_PGPORT="''${HTR_PGPORT:-5433}"
          export HTR_PGDB="''${HTR_PGDB:-htr_pipeline}"
          export HTR_PGUSER="''${HTR_PGUSER:-$USER}"

          # Variables estándar de libpq (usadas por psql, psycopg2, SQLAlchemy)
          export PGDATA="$HTR_PGDATA"
          export PGHOST="$HTR_PGRUN"
          export PGPORT="$HTR_PGPORT"
          export PGDATABASE="$HTR_PGDB"
          export PGUSER="$HTR_PGUSER"

          # URL de conexión completa para el pipeline Python
          export HTR_DB_URL="postgresql://$HTR_PGUSER@/$HTR_PGDB?host=$HTR_PGRUN&port=$HTR_PGPORT"
        '';

        # ── Script: db-init ────────────────────────────────────
        # Inicializa el cluster PostgreSQL y crea la BD.
        # Idempotente: no hace nada si el cluster ya existe.
        dbInitScript = pkgs.writeShellScriptBin "htr-db-init" ''
          set -euo pipefail
          ${dbEnvVars}

          echo "→ HTR_PGDATA : $HTR_PGDATA"
          echo "→ HTR_PGPORT : $HTR_PGPORT"
          echo "→ HTR_PGDB   : $HTR_PGDB"

          # Crear directorios si no existen
          mkdir -p "$HTR_PGDATA" "$HTR_PGRUN"

          # Inicializar cluster solo si está vacío
          if [ ! -f "$HTR_PGDATA/PG_VERSION" ]; then
            echo "▶ Inicializando cluster PostgreSQL en $HTR_PGDATA ..."
            ${postgresql}/bin/initdb \
              --pgdata="$HTR_PGDATA" \
              --auth=trust \
              --no-locale \
              --encoding=UTF8
            echo "✓ Cluster inicializado."
          else
            echo "✓ Cluster ya existe. Saltando initdb."
          fi

          # Configurar postgresql.conf para socket local sin root
          cat >> "$HTR_PGDATA/postgresql.conf" << PGCONF

          # HTR pipeline — configuración generada por htr-db-init
          unix_socket_directories = '$HTR_PGRUN'
          port = $HTR_PGPORT
          listen_addresses = ''        # solo socket Unix, sin TCP
          shared_preload_libraries = 'vector'
          log_min_messages = warning
          log_min_error_statement = error
          PGCONF

          echo "▶ Iniciando PostgreSQL..."
          ${postgresql}/bin/pg_ctl \
            -D "$HTR_PGDATA" \
            -l "$HTR_PGDATA/postgresql.log" \
            start

          # Esperar a que el servidor esté listo
          sleep 2
          ${postgresql}/bin/pg_isready -h "$HTR_PGRUN" -p "$HTR_PGPORT" \
            && echo "✓ PostgreSQL listo." \
            || { echo "✗ PostgreSQL no responde. Ver $HTR_PGDATA/postgresql.log"; exit 1; }

          # Crear base de datos si no existe
          if ! ${postgresql}/bin/psql \
               -h "$HTR_PGRUN" -p "$HTR_PGPORT" \
               -lqt | cut -d\| -f1 | grep -qw "$HTR_PGDB"; then
            echo "▶ Creando base de datos '$HTR_PGDB' ..."
            ${postgresql}/bin/createdb \
              -h "$HTR_PGRUN" -p "$HTR_PGPORT" \
              "$HTR_PGDB"
            echo "✓ Base de datos creada."
          else
            echo "✓ Base de datos '$HTR_PGDB' ya existe."
          fi

          echo ""
          echo "═══════════════════════════════════════════"
          echo "  BD local lista."
          echo "  Siguiente paso: htr-db-schema <ruta/schema_integrado.sql>"
          echo "═══════════════════════════════════════════"
        '';

        # ── Script: db-start ───────────────────────────────────
        dbStartScript = pkgs.writeShellScriptBin "htr-db-start" ''
          set -euo pipefail
          ${dbEnvVars}

          if ${postgresql}/bin/pg_isready \
               -h "$HTR_PGRUN" -p "$HTR_PGPORT" -q 2>/dev/null; then
            echo "✓ PostgreSQL ya está corriendo en puerto $HTR_PGPORT."
            exit 0
          fi

          if [ ! -f "$HTR_PGDATA/PG_VERSION" ]; then
            echo "✗ Cluster no inicializado. Corre primero: htr-db-init"
            exit 1
          fi

          echo "▶ Iniciando PostgreSQL..."
          ${postgresql}/bin/pg_ctl \
            -D "$HTR_PGDATA" \
            -l "$HTR_PGDATA/postgresql.log" \
            start
          sleep 2
          ${postgresql}/bin/pg_isready \
            -h "$HTR_PGRUN" -p "$HTR_PGPORT" \
            && echo "✓ PostgreSQL listo." \
            || { echo "✗ No responde. Ver $HTR_PGDATA/postgresql.log"; exit 1; }
        '';

        # ── Script: db-stop ────────────────────────────────────
        dbStopScript = pkgs.writeShellScriptBin "htr-db-stop" ''
          set -euo pipefail
          ${dbEnvVars}
          echo "▶ Deteniendo PostgreSQL..."
          ${postgresql}/bin/pg_ctl -D "$HTR_PGDATA" stop -m fast \
            && echo "✓ PostgreSQL detenido." \
            || echo "✗ No se pudo detener (¿está corriendo?)"
        '';

        # ── Script: db-schema ──────────────────────────────────
        # Aplica schema_integrado.sql. Idempotente por el IF NOT EXISTS.
        dbSchemaScript = pkgs.writeShellScriptBin "htr-db-schema" ''
          set -euo pipefail
          ${dbEnvVars}

          SCHEMA_FILE="''${1:-schema_integrado.sql}"

          if [ ! -f "$SCHEMA_FILE" ]; then
            echo "✗ No se encontró: $SCHEMA_FILE"
            echo "  Uso: htr-db-schema <ruta/schema_integrado.sql>"
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
          echo "▶ Verificando extensiones..."
          ${postgresql}/bin/psql \
            -h "$HTR_PGRUN" -p "$HTR_PGPORT" \
            -d "$HTR_PGDB" \
            -c "SELECT extname, extversion FROM pg_extension ORDER BY extname;"
        '';

        # ── Script: db-status ──────────────────────────────────
        dbStatusScript = pkgs.writeShellScriptBin "htr-db-status" ''
          set -euo pipefail
          ${dbEnvVars}

          echo "═══════════════════════════════════════════"
          echo "  Estado de la BD local"
          echo "═══════════════════════════════════════════"
          echo "  PGDATA   : $HTR_PGDATA"
          echo "  Socket   : $HTR_PGRUN"
          echo "  Puerto   : $HTR_PGPORT"
          echo "  Base     : $HTR_PGDB"
          echo "  DB_URL   : $HTR_DB_URL"
          echo "───────────────────────────────────────────"

          if ${postgresql}/bin/pg_isready \
               -h "$HTR_PGRUN" -p "$HTR_PGPORT" -q 2>/dev/null; then
            echo "  PostgreSQL: ✓ corriendo"
            echo ""
            echo "▶ Tablas existentes:"
            ${postgresql}/bin/psql \
              -h "$HTR_PGRUN" -p "$HTR_PGPORT" \
              -d "$HTR_PGDB" \
              -c "\dt public.* pipeline.* rag.*" 2>/dev/null \
              || echo "  (schema aún no aplicado)"
          else
            echo "  PostgreSQL: ✗ no está corriendo"
            echo "  Ejecuta: htr-db-start"
          fi
        '';

        # ── Script: setup-venv ─────────────────────────────────
        # Crea un virtualenv con las versiones exactas del
        # requirements.txt. Nix proporciona los compiladores y
        # librerías de sistema; pip instala las versiones pinadas.
        setupVenvScript = pkgs.writeShellScriptBin "htr-setup-venv" ''
          set -euo pipefail

          VENV_DIR="''${1:-.venv}"
          REQUIREMENTS="''${2:-requirements.txt}"

          if [ ! -f "$REQUIREMENTS" ]; then
            echo "✗ No se encontró: $REQUIREMENTS"
            echo "  Uso: htr-setup-venv [directorio_venv] [requirements.txt]"
            exit 1
          fi

          echo "▶ Creando virtualenv en $VENV_DIR ..."
          ${python}/bin/python -m venv "$VENV_DIR"

          echo "▶ Actualizando pip/setuptools/wheel..."
          "$VENV_DIR/bin/pip" install --quiet --upgrade pip setuptools wheel

          echo "▶ Instalando dependencias del pipeline (versiones exactas)..."
          "$VENV_DIR/bin/pip" install \
            --quiet \
            -r "$REQUIREMENTS"

          echo "▶ Instalando driver PostgreSQL + utilidades de BD..."
          "$VENV_DIR/bin/pip" install --quiet \
            psycopg2-binary \
            sqlalchemy \
            alembic

          echo ""
          echo "✓ Virtualenv listo en $VENV_DIR"
          echo ""
          echo "  Para activar manualmente:"
          echo "    source $VENV_DIR/bin/activate"
          echo ""
          echo "  Versiones instaladas:"
          "$VENV_DIR/bin/pip" list --format=columns | grep -E \
            "numpy|scipy|scikit|pandas|matplotlib|pillow|psycopg2|sqlalchemy"
        '';

        # ── Script: run-pipeline ───────────────────────────────
        # Punto de entrada principal. Detecta el venv, exporta
        # variables de BD y delega en run_pipeline.py.
        runPipelineScript = pkgs.writeShellScriptBin "htr-run-pipeline" ''
          set -euo pipefail
          ${dbEnvVars}

          VENV_DIR="''${HTR_VENV:-.venv}"
          PIPELINE_DIR="''${HTR_PIPELINE_DIR:-.}"

          # Verificar venv
          if [ ! -f "$VENV_DIR/bin/python" ]; then
            echo "✗ Virtualenv no encontrado en $VENV_DIR"
            echo "  Ejecuta primero: htr-setup-venv"
            exit 1
          fi

          # Verificar que PostgreSQL está corriendo
          if ! ${postgresql}/bin/pg_isready \
               -h "$HTR_PGRUN" -p "$HTR_PGPORT" -q 2>/dev/null; then
            echo "✗ PostgreSQL no está corriendo."
            echo "  Ejecuta: htr-db-start"
            exit 1
          fi

          echo "═══════════════════════════════════════════"
          echo "  HTR Cleaning Pipeline"
          echo "  DB  : $HTR_DB_URL"
          echo "  Paso: ''${1:-full}"
          echo "═══════════════════════════════════════════"

          # Exportar para que run_pipeline.py pueda leerlas
          export HTR_DB_URL
          export HTR_STEP="''${1:-full}"
          export HTR_BATCH_ID="''${2:-$(date +%Y%m%d_%H%M%S)}"
          export HTR_LOG_LEVEL="''${HTR_LOG_LEVEL:-INFO}"

          cd "$PIPELINE_DIR"
          "$VENV_DIR/bin/python" pipeline/run_pipeline.py \
            --step  "$HTR_STEP" \
            --batch "$HTR_BATCH_ID" \
            "''${@:3}"
        '';

        # ── Script: slurm-submit ───────────────────────────────
        # Genera y envía un job Slurm que corre el pipeline
        # dentro del entorno Nix, sin necesitar módulos del sistema.
        slurmSubmitScript = pkgs.writeShellScriptBin "htr-slurm-submit" ''
          set -euo pipefail
          ${dbEnvVars}

          STEP="''${1:-full}"
          BATCH_ID="''${2:-$(date +%Y%m%d_%H%M%S)}"
          LOGS_DIR="''${HTR_LOGS_DIR:-slurm-logs}"
          N_CPUS="''${HTR_SLURM_CPUS:-8}"
          MEM="''${HTR_SLURM_MEM:-32G}"
          TIME="''${HTR_SLURM_TIME:-12:00:00}"
          PARTITION="''${HTR_SLURM_PARTITION:-gpu}"
          GRES="''${HTR_SLURM_GRES:-gpu:1}"

          mkdir -p "$LOGS_DIR"

          # Script temporal para Slurm — usa nix develop para garantizar
          # el entorno reproducible dentro del job
          JOBSCRIPT=$(mktemp /tmp/htr-slurm-XXXXXX.sh)
          cat > "$JOBSCRIPT" << SLURM
          #!/usr/bin/env bash
          #SBATCH --job-name=htr-${STEP}-${BATCH_ID}
          #SBATCH --output=${LOGS_DIR}/htr-${STEP}-${BATCH_ID}-%j.out
          #SBATCH --error=${LOGS_DIR}/htr-${STEP}-${BATCH_ID}-%j.err
          #SBATCH --cpus-per-task=${N_CPUS}
          #SBATCH --mem=${MEM}
          #SBATCH --time=${TIME}
          #SBATCH --partition=${PARTITION}
          #SBATCH --gres=${GRES}

          set -euo pipefail

          echo "▶ Job Slurm iniciado: \$(date)"
          echo "  Nodo : \$SLURMD_NODENAME"
          echo "  Step : ${STEP}"
          echo "  Batch: ${BATCH_ID}"

          # Activar el entorno Nix. En el cluster, nix está disponible
          # pero el flake debe estar en el directorio del proyecto.
          cd "\$SLURM_SUBMIT_DIR"

          # Iniciar PostgreSQL si no está corriendo
          # (puede estar corriendo desde otro job en el mismo nodo)
          nix run .#htr-db-start 2>/dev/null || true

          # Correr el paso indicado
          nix run .#htr-run-pipeline -- ${STEP} ${BATCH_ID}

          echo "✓ Job completado: \$(date)"
          SLURM

          echo "▶ Enviando job Slurm..."
          echo "  Step   : $STEP"
          echo "  Batch  : $BATCH_ID"
          echo "  CPUs   : $N_CPUS"
          echo "  Memoria: $MEM"
          echo "  Tiempo : $TIME"
          echo "  GPUs   : $GRES"
          echo ""

          sbatch "$JOBSCRIPT"
          rm "$JOBSCRIPT"
        '';

      in {
        # ── Paquetes exportados ──────────────────────────────────
        packages = {
          inherit postgresql pythonEnv;
        };

        # ── Apps (ejecutables vía nix run .#nombre) ─────────────
        apps = {
          htr-db-init    = { type = "app"; program = "${dbInitScript}/bin/htr-db-init"; };
          htr-db-start   = { type = "app"; program = "${dbStartScript}/bin/htr-db-start"; };
          htr-db-stop    = { type = "app"; program = "${dbStopScript}/bin/htr-db-stop"; };
          htr-db-schema  = { type = "app"; program = "${dbSchemaScript}/bin/htr-db-schema"; };
          htr-db-status  = { type = "app"; program = "${dbStatusScript}/bin/htr-db-status"; };
          htr-setup-venv = { type = "app"; program = "${setupVenvScript}/bin/htr-setup-venv"; };
          htr-run-pipeline = { type = "app"; program = "${runPipelineScript}/bin/htr-run-pipeline"; };
          htr-slurm-submit = { type = "app"; program = "${slurmSubmitScript}/bin/htr-slurm-submit"; };
        };

        # ── Shell de desarrollo (nix develop) ───────────────────
        # Al entrar al shell:
        #   1. PostgreSQL arranca automáticamente si tiene cluster
        #   2. Variables de BD exportadas
        #   3. Todos los comandos htr-* disponibles
        #   4. Si existe .venv, se activa
        devShells.default = pkgs.mkShell {
          name = "htr-pipeline";

          buildInputs = [
            postgresql
            pythonEnv
            pkgs.gcc
            pkgs.gnumake
            pkgs.zlib
            pkgs.openssl
            pkgs.libffi
            # comandos htr-*
            dbInitScript
            dbStartScript
            dbStopScript
            dbSchemaScript
            dbStatusScript
            setupVenvScript
            runPipelineScript
            slurmSubmitScript
          ];

          shellHook = ''
            # ── Variables de entorno ─────────────────────────────
            ${dbEnvVars}

            # ── Activar venv si existe ───────────────────────────
            if [ -f ".venv/bin/activate" ]; then
              source .venv/bin/activate
              echo "✓ Virtualenv .venv activado."
            fi

            # ── Arrancar PostgreSQL si el cluster está inicializado
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
              echo "⚠ Cluster PostgreSQL no inicializado."
              echo "  Ejecuta: htr-db-init"
            fi

            echo ""
            echo "╔══════════════════════════════════════════╗"
            echo "║  HTR Pipeline — entorno listo            ║"
            echo "╠══════════════════════════════════════════╣"
            echo "║  htr-db-init       inicializar BD local  ║"
            echo "║  htr-db-start      arrancar PostgreSQL   ║"
            echo "║  htr-db-stop       detener PostgreSQL    ║"
            echo "║  htr-db-schema     aplicar schema SQL    ║"
            echo "║  htr-db-status     estado de la BD       ║"
            echo "║  htr-setup-venv    crear virtualenv      ║"
            echo "║  htr-run-pipeline  correr pipeline       ║"
            echo "║  htr-slurm-submit  enviar job a Slurm    ║"
            echo "╚══════════════════════════════════════════╝"
            echo "  DB_URL: $HTR_DB_URL"
            echo ""
          '';
        };
      }
    );
}
