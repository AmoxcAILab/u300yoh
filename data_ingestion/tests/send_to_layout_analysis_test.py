"""
data_ingestion/tests/send_to_layout_analysis_test.py
──────────────────────────────────────────────────────
Tests de integración para send_to_layout_analysis.py.

Los tests mockean la API de Transkribus para no requerir
credenciales reales, pero usan una BD real para verificar
que las operaciones se registran correctamente.

Ejecutar:
  pytest data_ingestion/tests/send_to_layout_analysis_test.py -v
"""

import pytest
from pathlib import Path
from unittest.mock import patch, MagicMock

from database.migration.db import check_connection, get_conn, Operations
from database.crud_operations import Collections, Documents, Images
from data_ingestion.send_to_layout_analysis import send_to_layout_analysis


@pytest.fixture(scope="module")
def db_available():
    if not check_connection():
        pytest.skip("BD no disponible.")


@pytest.fixture
def conn(db_available):
    with get_conn() as c:
        c.cursor().execute("SAVEPOINT layout_test_start")
        yield c
        c.cursor().execute("ROLLBACK TO SAVEPOINT layout_test_start")


@pytest.fixture
def image_with_file(conn, tmp_path):
    """Crea colección, documento, imagen y un archivo de imagen de prueba."""
    col_id = Collections.create(
        conn, collection_name="test_layout_col", collection_type="AGN"
    )
    doc_id = Documents.create(
        conn, collection_id=col_id, document_filename="test_layout_doc"
    )
    # Crear archivo JPEG mínimo
    img_file = tmp_path / "pagina_001.jpg"
    img_file.write_bytes(b"\xFF\xD8\xFF\xE0" + b"\x00" * 16)

    image_id = Images.create(
        conn,
        document_id=doc_id,
        image_filename=str(img_file),
        image_type="original",
        page_number=1,
    )
    return {"image_id": image_id, "img_file": img_file, "doc_id": doc_id}


def _mock_transkribus_env(monkeypatch):
    """Configura variables de entorno mínimas para Transkribus."""
    monkeypatch.setenv("TRANSKRIBUS_SESSION", "fake_session_cookie")
    monkeypatch.setenv("TRANSKRIBUS_COLLECTION_ID", "999")


def test_send_to_layout_analysis_registers_operation(
    image_with_file, conn, monkeypatch
):
    """La operación layout_retrieved debe quedar registrada con status running."""
    _mock_transkribus_env(monkeypatch)

    fake_job_id = "TRK-LAYOUT-001"

    with patch("data_ingestion.send_to_layout_analysis._submit_layout_job",
               return_value=fake_job_id):
        result = send_to_layout_analysis(
            image_id=image_with_file["image_id"],
            wait=False,
        )

    assert result["transkribus_job_id"] == fake_job_id
    assert result["status"] == "running"
    assert result["operation_id"] is not None


def test_send_to_layout_analysis_stores_transkribus_job_id(
    image_with_file, conn, monkeypatch
):
    """El transkribus_job_id debe poder recuperarse con Operations.get_transkribus_job_id."""
    _mock_transkribus_env(monkeypatch)
    fake_job_id = "TRK-LAYOUT-002"

    with patch("data_ingestion.send_to_layout_analysis._submit_layout_job",
               return_value=fake_job_id):
        send_to_layout_analysis(
            image_id=image_with_file["image_id"],
            wait=False,
        )

    retrieved = Operations.get_transkribus_job_id(
        conn, "layout_retrieved", "image", image_with_file["image_id"]
    )
    assert retrieved == fake_job_id


def test_send_to_layout_analysis_wait_updates_status(
    image_with_file, conn, monkeypatch, tmp_path
):
    """Con --wait, la operación debe quedar completed tras el poll."""
    _mock_transkribus_env(monkeypatch)
    fake_job_id = "TRK-LAYOUT-003"
    fake_xml    = b"<xml>layout</xml>"

    finished_status = {"state": "FINISHED"}

    with (
        patch("data_ingestion.send_to_layout_analysis._submit_layout_job",
              return_value=fake_job_id),
        patch("data_ingestion.send_to_layout_analysis._poll_job_status",
              return_value=finished_status),
        patch("data_ingestion.send_to_layout_analysis._save_layout_xml",
              return_value=tmp_path / "layout.xml"),
    ):
        result = send_to_layout_analysis(
            image_id=image_with_file["image_id"],
            wait=True,
        )

    assert result["status"] == "completed"


def test_send_to_layout_analysis_missing_session_raises(image_with_file, monkeypatch):
    """Sin TRANSKRIBUS_SESSION debe lanzar EnvironmentError."""
    monkeypatch.delenv("TRANSKRIBUS_SESSION", raising=False)
    monkeypatch.delenv("TRANSKRIBUS_COLLECTION_ID", raising=False)

    with pytest.raises(EnvironmentError, match="TRANSKRIBUS_SESSION"):
        send_to_layout_analysis(image_id=image_with_file["image_id"])


def test_send_to_layout_analysis_missing_image_file(conn, db_available, monkeypatch):
    """Si el archivo de imagen no existe en disco, debe lanzar FileNotFoundError."""
    _mock_transkribus_env(monkeypatch)

    col_id = Collections.create(
        conn, collection_name="test_layout_nofile", collection_type="AGN"
    )
    doc_id = Documents.create(
        conn, collection_id=col_id, document_filename="doc_nofile"
    )
    image_id = Images.create(
        conn,
        document_id=doc_id,
        image_filename="/ruta/inexistente/imagen.jpg",
        image_type="original",
        page_number=1,
    )

    with pytest.raises(FileNotFoundError):
        send_to_layout_analysis(image_id=image_id)
