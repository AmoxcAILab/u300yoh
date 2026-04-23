"""
data_ingestion/tests/import_collection_test.py
────────────────────────────────────────────────
Tests de integración para import_collection.py.

Ejecutar:
  pytest data_ingestion/tests/import_collection_test.py -v
"""

import pytest
from pathlib import Path

from database.migration.db import check_connection, get_conn, Operations
from database.crud_operations import Collections, Documents, Images
from data_ingestion.register_collection import register_collection
from data_ingestion.import_collection import import_collection


@pytest.fixture(scope="module")
def db_available():
    if not check_connection():
        pytest.skip("BD no disponible.")


@pytest.fixture
def source_collection_dir(tmp_path):
    """Estructura de colección con documentos e imágenes."""
    for doc_name in ["doc_a", "doc_b"]:
        doc_dir = tmp_path / doc_name
        doc_dir.mkdir()
        for i in range(1, 3):
            (doc_dir / f"img_{i:02d}.jpg").write_bytes(b"\xFF\xD8\xFF")
    return tmp_path


@pytest.fixture
def registered_collection_id(source_collection_dir, db_available):
    """Registra una colección base para usarla en tests de import."""
    summary = register_collection(
        source_dir=source_collection_dir,
        collection_name="test_import_base_col",
        collection_type="AGN",
    )
    return summary["collection_id"]


def test_import_collection_copies_images(
    registered_collection_id, source_collection_dir, db_available, monkeypatch
):
    """import_collection debe registrar imágenes adicionales."""
    summary = import_collection(
        collection_id=registered_collection_id,
        source_dir=source_collection_dir,
    )
    assert summary["n_images_imported"] >= 4  # 2 docs × 2 imágenes


def test_import_collection_registers_images_downloaded_operation(
    registered_collection_id, source_collection_dir, db_available
):
    import_collection(
        collection_id=registered_collection_id,
        source_dir=source_collection_dir,
    )
    with get_conn() as conn:
        assert Operations.has_completed(
            conn, "images_downloaded", "collection", registered_collection_id
        )


def test_import_collection_nonexistent_collection_raises(db_available, tmp_path):
    with pytest.raises(ValueError, match="no encontrada"):
        import_collection(collection_id=-999, source_dir=tmp_path)


def test_import_collection_nonexistent_dir_raises(registered_collection_id, tmp_path, db_available):
    with pytest.raises(ValueError, match="no existe"):
        import_collection(
            collection_id=registered_collection_id,
            source_dir=tmp_path / "no_existe",
        )
