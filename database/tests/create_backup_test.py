"""
database/tests/create_backup_test.py
──────────────────────────────────────
Tests para database/create_backup.py.

Ejecutar:
  pytest database/tests/create_backup_test.py -v
"""

import re
import pytest
from pathlib import Path

from database.migration.db import check_connection


@pytest.fixture(scope="module")
def db_available():
    if not check_connection():
        pytest.skip("BD no disponible. Ejecuta htr_db_start primero.")


def test_backup_creates_file(db_available, tmp_path):
    """El backup debe crear un archivo en el directorio de salida."""
    from database.create_backup import create_backup

    result = create_backup(output_dir=tmp_path, format="plain")
    backup_path = Path(result["backup_path"])
    assert backup_path.exists()
    assert backup_path.suffix in (".sql", ".dump")
    assert backup_path.stat().st_size > 0


def test_backup_filename_has_timestamp(db_available, tmp_path):
    """El nombre del archivo debe incluir un timestamp YYYYMMDD_HHMMSS."""
    from database.create_backup import create_backup

    result = create_backup(output_dir=tmp_path)
    filename = Path(result["backup_path"]).name
    assert re.search(r"\d{8}_\d{6}", filename)


def test_backup_size_reported(db_available, tmp_path):
    """El resultado debe incluir size_mb > 0."""
    from database.create_backup import create_backup

    result = create_backup(output_dir=tmp_path, format="plain")
    assert result["size_mb"] > 0


def test_backup_registers_operation(db_available, tmp_path):
    """La operación db_backup_created debe quedar registrada en BD."""
    from database.create_backup import create_backup
    from database.migration.db import get_conn

    result = create_backup(output_dir=tmp_path)
    assert result["operation_id"] is not None

    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT o.operation_id
            FROM public.operations o
            JOIN public.operation_types ot USING (operation_type_id)
            WHERE ot.operation_type_name = 'db_backup_created'
            ORDER BY o.logged_at DESC
            LIMIT 1
            """
        )
        assert cur.fetchone() is not None


def test_backup_invalid_format_raises(db_available, tmp_path):
    """Un formato pg_dump no válido debe lanzar ValueError."""
    from database.create_backup import create_backup

    with pytest.raises(ValueError, match="Formato no válido"):
        create_backup(output_dir=tmp_path, format="invalid_fmt")
