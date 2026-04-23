"""
data_ingestion/tests/register_ground_truth_test.py
────────────────────────────────────────────────────
Tests de integración para register_ground_truth.py.

Ejecutar:
  pytest data_ingestion/tests/register_ground_truth_test.py -v
"""

import pytest
from pathlib import Path

from database.migration.db import check_connection, get_conn, Operations
from database.crud_operations import Collections, Documents, Images, HTR, GroundTruth
from data_ingestion.register_ground_truth import register_ground_truth


@pytest.fixture(scope="module")
def db_available():
    if not check_connection():
        pytest.skip("BD no disponible.")


@pytest.fixture
def conn(db_available):
    with get_conn() as c:
        c.cursor().execute("SAVEPOINT gt_test_start")
        yield c
        c.cursor().execute("ROLLBACK TO SAVEPOINT gt_test_start")


@pytest.fixture
def collection_with_htr(conn):
    """Crea colección, documentos, imágenes y HTR de prueba."""
    collection_id = Collections.create(
        conn, collection_name="test_gt_col", collection_type="AGN"
    )
    doc_id = Documents.create(
        conn, collection_id=collection_id, document_filename="documento_gt_test"
    )
    image_id = Images.create(
        conn, document_id=doc_id,
        image_filename="pagina_001.jpg", image_type="original", page_number=1
    )
    htr_id = HTR.create(
        conn, image_id=image_id,
        htr_path="data_ingestion/transkribús/test_gt_col/documento_gt_test/pagina_001_htr.txt"
    )
    return {"collection_id": collection_id, "document_id": doc_id,
            "image_id": image_id, "htr_id": htr_id}


@pytest.fixture
def ground_truth_dir(tmp_path, collection_with_htr):
    """Crea estructura de ground_truth que coincide con el documento de prueba."""
    doc_dir = tmp_path / "documento_gt_test"
    doc_dir.mkdir()
    # El GT debe llamarse igual que la imagen (sin extensión)
    gt_file = doc_dir / "pagina_001.txt"
    gt_file.write_text("Texto ground truth de prueba.", encoding="utf-8")
    return tmp_path


def test_register_ground_truth_success(ground_truth_dir, collection_with_htr, conn):
    summary = register_ground_truth(
        collection_id=collection_with_htr["collection_id"],
        ground_truth_dir=ground_truth_dir,
    )
    assert summary["n_registered"] == 1
    assert summary["n_no_htr_found"] == 0


def test_register_ground_truth_records_operation(ground_truth_dir, collection_with_htr, conn):
    register_ground_truth(
        collection_id=collection_with_htr["collection_id"],
        ground_truth_dir=ground_truth_dir,
    )
    # Verificar que la operación ground_truth_registered fue registrada en el HTR
    assert Operations.has_completed(
        conn, "ground_truth_registered", "htr", collection_with_htr["htr_id"]
    )


def test_register_ground_truth_no_match_warning(tmp_path, collection_with_htr, conn):
    """GT con nombre diferente al HTR debe generar warning, no fallar."""
    doc_dir = tmp_path / "documento_gt_test"
    doc_dir.mkdir()
    # Nombre que no coincide con ninguna imagen
    (doc_dir / "pagina_sin_match.txt").write_text("texto", encoding="utf-8")

    summary = register_ground_truth(
        collection_id=collection_with_htr["collection_id"],
        ground_truth_dir=tmp_path,
    )
    assert summary["n_no_htr_found"] >= 1
    assert summary["n_registered"] == 0


def test_register_ground_truth_nonexistent_dir_raises(collection_with_htr, conn):
    with pytest.raises(ValueError, match="no existe"):
        register_ground_truth(
            collection_id=collection_with_htr["collection_id"],
            ground_truth_dir=Path("/ruta/inexistente"),
        )
