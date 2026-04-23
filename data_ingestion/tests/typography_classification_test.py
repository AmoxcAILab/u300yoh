"""
data_ingestion/tests/typography_classification_test.py
────────────────────────────────────────────────────────
Tests de integración para typography_classification.py.

Mockea el modelo local y el servidor Gradio para no requerir
GPU ni credenciales externas. Verifica el registro en BD.

Ejecutar:
  pytest data_ingestion/tests/typography_classification_test.py -v
"""

import json
import pytest
from pathlib import Path
from unittest.mock import patch, MagicMock

from database.migration.db import check_connection, get_conn, Operations
from database.crud_operations import Collections, Documents, Images
from data_ingestion.typography_classification import classify_typography


@pytest.fixture(scope="module")
def db_available():
    if not check_connection():
        pytest.skip("BD no disponible.")


@pytest.fixture
def conn(db_available):
    with get_conn() as c:
        c.cursor().execute("SAVEPOINT typography_test_start")
        yield c
        c.cursor().execute("ROLLBACK TO SAVEPOINT typography_test_start")


@pytest.fixture
def image_with_file(conn, tmp_path):
    """Crea imagen en BD con archivo JPEG de prueba en disco."""
    col_id = Collections.create(
        conn, collection_name="test_typo_col", collection_type="AGN"
    )
    doc_id = Documents.create(
        conn, collection_id=col_id, document_filename="test_typo_doc"
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
    return {"image_id": image_id, "doc_id": doc_id, "img_file": img_file}


@pytest.fixture
def local_model_dir(tmp_path):
    """Crea un directorio de modelo dummy con config.json."""
    model_dir = tmp_path / "models" / "typography"
    model_dir.mkdir(parents=True)
    config = {
        "id2label": {
            "0": "humanistica",
            "1": "cortesana",
            "2": "procesal",
        }
    }
    (model_dir / "config.json").write_text(json.dumps(config), encoding="utf-8")
    return model_dir


def test_classify_typography_with_local_model(image_with_file, conn, local_model_dir):
    """Clasificación con modelo local debe registrar operación y devolver tipo válido."""
    with patch(
        "data_ingestion.typography_classification._classify_with_local_model",
        return_value=("humanistica", 0.92),
    ):
        result = classify_typography(
            image_id=image_with_file["image_id"],
            model_dir=local_model_dir,
        )

    assert result["calligraphy_type"] == "humanistica"
    assert 0.0 <= result["confidence"] <= 1.0
    assert result["operation_id"] is not None


def test_classify_typography_registers_operation(image_with_file, conn, local_model_dir):
    """La operación typography_classified debe quedar registrada en BD."""
    with patch(
        "data_ingestion.typography_classification._classify_with_local_model",
        return_value=("cortesana", 0.85),
    ):
        classify_typography(
            image_id=image_with_file["image_id"],
            model_dir=local_model_dir,
        )

    assert Operations.has_completed(
        conn, "typography_classified", "image", image_with_file["image_id"]
    )


def test_classify_typography_updates_document_calligraphy_type(
    image_with_file, conn, local_model_dir
):
    """El calligraphy_type del documento debe actualizarse en BD."""
    with patch(
        "data_ingestion.typography_classification._classify_with_local_model",
        return_value=("procesal", 0.78),
    ):
        classify_typography(
            image_id=image_with_file["image_id"],
            model_dir=local_model_dir,
        )

    cur = conn.cursor()
    cur.execute(
        "SELECT calligraphy_type FROM public.documents WHERE document_id = %s",
        (image_with_file["doc_id"],),
    )
    row = cur.fetchone()
    assert row is not None
    assert row[0] == "procesal"


def test_classify_typography_unknown_type_becomes_default(
    image_with_file, conn, local_model_dir
):
    """Un tipo de caligrafía no reconocido debe normalizarse a 'default'."""
    with patch(
        "data_ingestion.typography_classification._classify_with_local_model",
        return_value=("tipo_desconocido_xyz", 0.50),
    ):
        result = classify_typography(
            image_id=image_with_file["image_id"],
            model_dir=local_model_dir,
        )

    assert result["calligraphy_type"] == "default"


def test_classify_typography_no_backend_raises(image_with_file, monkeypatch):
    """Sin modelo local ni GRADIO_URL debe lanzar EnvironmentError."""
    monkeypatch.delenv("GRADIO_URL", raising=False)

    with pytest.raises(EnvironmentError):
        classify_typography(
            image_id=image_with_file["image_id"],
            model_dir=None,
        )


def test_classify_typography_with_gradio(image_with_file, conn, monkeypatch):
    """Clasificación vía Gradio debe funcionar cuando no hay modelo local."""
    monkeypatch.setenv("GRADIO_URL", "http://localhost:7860")

    with patch(
        "data_ingestion.typography_classification._classify_with_gradio",
        return_value=("encadenada", 0.88),
    ):
        result = classify_typography(
            image_id=image_with_file["image_id"],
            model_dir=None,
        )

    assert result["calligraphy_type"] == "encadenada"
