"""
data_ingestion/tests/register_collection_test.py
──────────────────────────────────────────────────
Tests de integración para register_collection.py.

Ejecutar:
  pytest data_ingestion/tests/register_collection_test.py -v
"""

import pytest
from pathlib import Path

from database.migration.db import check_connection, get_conn, Operations
from database.crud_operations import Collections, Documents, Images
from data_ingestion.register_collection import register_collection


@pytest.fixture(scope="module")
def db_available():
    if not check_connection():
        pytest.skip("BD no disponible.")


@pytest.fixture
def conn(db_available):
    with get_conn() as c:
        c.cursor().execute("SAVEPOINT test_start")
        yield c
        c.cursor().execute("ROLLBACK TO SAVEPOINT test_start")


@pytest.fixture
def sample_collection_dir(tmp_path):
    """Crea una estructura de colección de prueba en tmp_path."""
    # Crear subdirectorios de documentos
    for doc_name in ["expediente_001", "expediente_002"]:
        doc_dir = tmp_path / doc_name
        doc_dir.mkdir()
        # Crear imágenes de prueba (archivos vacíos)
        for i in range(1, 4):
            (doc_dir / f"pagina_{i:03d}.jpg").write_bytes(b"\xFF\xD8\xFF")  # header JPEG mínimo

    # CSV de metadatos
    csv_path = tmp_path / "test_collection_metadata.csv"
    csv_path.write_text(
        "document_name,serie,siglo\n"
        "expediente_001,Flotas,XVII\n"
        "expediente_002,Flotas,XVIII\n",
        encoding="utf-8",
    )
    return tmp_path


def test_register_collection_creates_collection(sample_collection_dir, db_available):
    summary = register_collection(
        source_dir=sample_collection_dir,
        collection_name="test_register_col",
        collection_type="AGN",
    )
    assert summary["collection_id"] is not None
    assert isinstance(summary["collection_id"], int)


def test_register_collection_counts_documents(sample_collection_dir, db_available):
    summary = register_collection(
        source_dir=sample_collection_dir,
        collection_name="test_register_docs",
        collection_type="AGN",
    )
    assert summary["n_documents"] == 2


def test_register_collection_counts_images(sample_collection_dir, db_available):
    summary = register_collection(
        source_dir=sample_collection_dir,
        collection_name="test_register_imgs",
        collection_type="AGN",
    )
    # 2 documentos × 3 imágenes = 6
    assert summary["n_images"] == 6


def test_register_collection_records_operations(sample_collection_dir, db_available):
    summary = register_collection(
        source_dir=sample_collection_dir,
        collection_name="test_register_ops",
        collection_type="AGN",
    )
    with get_conn() as conn:
        assert Operations.has_completed(
            conn, "collection_registered", "collection", summary["collection_id"]
        )
        for doc in summary["documents"]:
            assert Operations.has_completed(
                conn, "document_registered", "document", doc["document_id"]
            )


def test_register_collection_empty_dir_raises(tmp_path, db_available):
    nonexistent = tmp_path / "no_existe"
    with pytest.raises(ValueError, match="no existe"):
        register_collection(
            source_dir=nonexistent,
            collection_name="test_empty",
        )
