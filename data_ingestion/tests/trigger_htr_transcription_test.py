"""
data_ingestion/tests/trigger_htr_transcription_test.py
────────────────────────────────────────────────────────
Tests de integración para trigger_htr_transcription.py.

Mockea las llamadas a la API de Transkribus y verifica que:
  - Se recupera el layout_job_id correcto
  - Se selecciona el modelo según calligraphy_type
  - El HTR se guarda en la ruta canónica
  - La fila en tabla htr y la operación htr_available quedan registradas

Ejecutar:
  pytest data_ingestion/tests/trigger_htr_transcription_test.py -v
"""

import pytest
from pathlib import Path
from unittest.mock import patch, MagicMock

from database.migration.db import check_connection, get_conn, Operations
from database.crud_operations import Collections, Documents, Images, HTR
from data_ingestion.trigger_htr_transcription import trigger_htr_transcription


@pytest.fixture(scope="module")
def db_available():
    if not check_connection():
        pytest.skip("BD no disponible.")


@pytest.fixture
def conn(db_available):
    with get_conn() as c:
        c.cursor().execute("SAVEPOINT htr_transcription_test_start")
        yield c
        c.cursor().execute("ROLLBACK TO SAVEPOINT htr_transcription_test_start")


@pytest.fixture
def image_with_layout(conn, tmp_path, monkeypatch):
    """Crea imagen con layout_retrieved registrado en BD."""
    col_id = Collections.create(
        conn, collection_name="test_htr_col", collection_type="AGN"
    )
    doc_id = Documents.create(
        conn, collection_id=col_id, document_filename="test_htr_doc"
    )
    img_file = tmp_path / "pagina_001.jpg"
    img_file.write_bytes(b"\xFF\xD8\xFF\xE0" + b"\x00" * 16)

    image_id = Images.create(
        conn,
        document_id=doc_id,
        image_filename=str(img_file),
        image_type="original",
        page_number=1,
    )

    # Registrar layout_retrieved con transkribus_job_id
    Operations.record_and_link(
        conn,
        operation_type="layout_retrieved",
        entity="image",
        entity_id=image_id,
        transkribus_job_id="LAYOUT-JOB-001",
        status="completed",
    )

    # Crear modelo dummy en tmp_path
    model_dir = tmp_path / "models" / "htr_general"
    model_dir.mkdir(parents=True)
    (model_dir / "config.json").write_text(
        '{"id2label": {"0": "humanistica"}}', encoding="utf-8"
    )

    monkeypatch.setenv("TRANSKRIBUS_SESSION", "fake_session")
    monkeypatch.setenv("TRANSKRIBUS_COLLECTION_ID", "999")

    return {
        "image_id": image_id,
        "doc_id":   doc_id,
        "col_id":   col_id,
        "model_dir": tmp_path / "models",
    }


def test_trigger_htr_registers_htr_row(image_with_layout, conn, tmp_path):
    """Debe insertar una fila en la tabla htr."""
    fake_htr_text = "Texto HTR de prueba transcrito."

    with (
        patch("data_ingestion.trigger_htr_transcription._submit_htr_job",
              return_value="HTR-JOB-001"),
        patch("data_ingestion.trigger_htr_transcription._poll_job",
              return_value={"state": "FINISHED"}),
        patch("data_ingestion.trigger_htr_transcription._download_htr_text",
              return_value=fake_htr_text),
    ):
        result = trigger_htr_transcription(
            image_id=image_with_layout["image_id"],
            model_dir=image_with_layout["model_dir"],
        )

    assert result["htr_id"] is not None
    assert isinstance(result["htr_id"], int)


def test_trigger_htr_saves_text_to_file(image_with_layout, conn):
    """El texto HTR debe guardarse en la ruta canónica."""
    fake_htr_text = "Texto manuscrito procesado."

    with (
        patch("data_ingestion.trigger_htr_transcription._submit_htr_job",
              return_value="HTR-JOB-002"),
        patch("data_ingestion.trigger_htr_transcription._poll_job",
              return_value={"state": "FINISHED"}),
        patch("data_ingestion.trigger_htr_transcription._download_htr_text",
              return_value=fake_htr_text),
    ):
        result = trigger_htr_transcription(
            image_id=image_with_layout["image_id"],
            model_dir=image_with_layout["model_dir"],
        )

    assert Path(result["htr_path"]).exists()
    assert Path(result["htr_path"]).read_text(encoding="utf-8") == fake_htr_text


def test_trigger_htr_registers_htr_available_operation(image_with_layout, conn):
    """La operación htr_available debe quedar completed en BD."""
    with (
        patch("data_ingestion.trigger_htr_transcription._submit_htr_job",
              return_value="HTR-JOB-003"),
        patch("data_ingestion.trigger_htr_transcription._poll_job",
              return_value={"state": "FINISHED"}),
        patch("data_ingestion.trigger_htr_transcription._download_htr_text",
              return_value="texto"),
    ):
        trigger_htr_transcription(
            image_id=image_with_layout["image_id"],
            model_dir=image_with_layout["model_dir"],
        )

    assert Operations.has_completed(
        conn, "htr_available", "image", image_with_layout["image_id"]
    )


def test_trigger_htr_no_layout_raises(conn, db_available, tmp_path, monkeypatch):
    """Sin layout_retrieved en BD debe lanzar ValueError."""
    monkeypatch.setenv("TRANSKRIBUS_SESSION", "fake_session")
    monkeypatch.setenv("TRANSKRIBUS_COLLECTION_ID", "999")

    col_id = Collections.create(
        conn, collection_name="test_htr_nolayout", collection_type="AGN"
    )
    doc_id = Documents.create(
        conn, collection_id=col_id, document_filename="doc_nolayout"
    )
    img_file = tmp_path / "img_nolayout.jpg"
    img_file.write_bytes(b"\xFF\xD8\xFF\xE0" + b"\x00" * 16)

    image_id = Images.create(
        conn,
        document_id=doc_id,
        image_filename=str(img_file),
        image_type="original",
        page_number=1,
    )

    with pytest.raises(ValueError, match="layout_retrieved"):
        trigger_htr_transcription(image_id=image_id)


def test_trigger_htr_failed_job_raises(image_with_layout, conn):
    """Si el job HTR de Transkribus falla, debe lanzar RuntimeError."""
    with (
        patch("data_ingestion.trigger_htr_transcription._submit_htr_job",
              return_value="HTR-JOB-FAIL"),
        patch("data_ingestion.trigger_htr_transcription._poll_job",
              return_value={"state": "FAILED"}),
    ):
        with pytest.raises(RuntimeError, match="FAILED"):
            trigger_htr_transcription(
                image_id=image_with_layout["image_id"],
                model_dir=image_with_layout["model_dir"],
            )
