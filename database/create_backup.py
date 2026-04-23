"""
database/create_backup.py
──────────────────────────
Genera un backup de la BD con pg_dump y registra la operación
db_backup_created en la tabla operations.

El nombre del archivo sigue el patrón:
  htr_pipeline_YYYYMMDD_HHMMSS.dump

Uso:
  python create_backup.py
  python create_backup.py --output-dir /backups --format plain
"""

import argparse
import os
import subprocess
import shutil
from datetime import datetime
from pathlib import Path

from database.migration.db import get_conn, Operations


# Formatos soportados por pg_dump
VALID_FORMATS = {"custom", "plain", "directory", "tar"}
DEFAULT_FORMAT = "custom"   # .dump binario, el más versátil para pg_restore


def create_backup(
    output_dir: Path = Path("."),
    format: str = DEFAULT_FORMAT,
    collaborator_id: int | None = None,
) -> dict:
    """
    Ejecuta pg_dump y guarda el archivo en output_dir.

    Devuelve dict con backup_path y operation_id.
    """
    if format not in VALID_FORMATS:
        raise ValueError(
            f"Formato no válido: '{format}'. "
            f"Opciones: {', '.join(sorted(VALID_FORMATS))}"
        )

    output_dir = Path(output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    # ── Verificar que pg_dump está disponible ──────────────────────
    pg_dump = shutil.which("pg_dump")
    if pg_dump is None:
        raise RuntimeError(
            "pg_dump no encontrado en PATH. "
            "Asegúrate de estar dentro del entorno Nix (nix develop)."
        )

    # ── Leer variables de entorno de BD ───────────────────────────
    pg_host = os.environ.get("PGHOST", "")
    pg_port = os.environ.get("PGPORT", "5433")
    pg_db   = os.environ.get("PGDATABASE", "htr_pipeline")
    pg_user = os.environ.get("PGUSER", os.environ.get("USER", "postgres"))

    if not pg_host:
        raise EnvironmentError(
            "Variable de entorno PGHOST no definida. "
            "Ejecuta desde el entorno Nix (nix develop)."
        )

    # ── Nombre del archivo ─────────────────────────────────────────
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    ext = ".sql" if format == "plain" else ".dump"
    filename = f"htr_pipeline_{timestamp}{ext}"
    backup_path = output_dir / filename

    # ── Ejecutar pg_dump ───────────────────────────────────────────
    cmd = [
        pg_dump,
        f"--host={pg_host}",
        f"--port={pg_port}",
        f"--username={pg_user}",
        f"--dbname={pg_db}",
        f"--format={format}",
        f"--file={backup_path}",
        "--no-password",
        "--blobs",
    ]

    print(f"▶ Ejecutando pg_dump...")
    print(f"  BD      : {pg_db} en {pg_host}:{pg_port}")
    print(f"  Formato : {format}")
    print(f"  Salida  : {backup_path}")

    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
    )

    if result.returncode != 0:
        raise RuntimeError(
            f"pg_dump falló (código {result.returncode}):\n{result.stderr}"
        )

    size_mb = backup_path.stat().st_size / (1024 * 1024)
    print(f"  ✓ Backup completado ({size_mb:.1f} MB)")

    # ── Registrar operación en BD ──────────────────────────────────
    with get_conn() as conn:
        op_id = Operations.record(
            conn,
            operation_type="db_backup_created",
            collaborator_id=collaborator_id,
            status="completed",
        )
        # Guardar la ruta del backup como nota en la operación
        cur = conn.cursor()
        cur.execute(
            "UPDATE public.operations SET note = %s WHERE operation_id = %s",
            (str(backup_path), op_id),
        )

    return {
        "backup_path":  str(backup_path),
        "size_mb":      size_mb,
        "operation_id": op_id,
    }


def main():
    parser = argparse.ArgumentParser(
        description="Crear backup de la BD HTR Pipeline con pg_dump."
    )
    parser.add_argument(
        "--output-dir", type=Path, default=Path("."),
        help="Directorio donde guardar el backup (default: directorio actual)."
    )
    parser.add_argument(
        "--format", choices=sorted(VALID_FORMATS), default=DEFAULT_FORMAT,
        help=f"Formato pg_dump (default: {DEFAULT_FORMAT})."
    )
    parser.add_argument("--collaborator-id", type=int, default=None)
    args = parser.parse_args()

    result = create_backup(
        output_dir=args.output_dir,
        format=args.format,
        collaborator_id=args.collaborator_id,
    )

    print()
    print("═" * 50)
    print(f"  backup_path  : {result['backup_path']}")
    print(f"  size_mb      : {result['size_mb']:.1f}")
    print(f"  operation_id : {result['operation_id']}")
    print("═" * 50)


if __name__ == "__main__":
    main()
