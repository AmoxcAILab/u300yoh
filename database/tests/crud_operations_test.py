"""
database/tests/crud_operations_test.py
────────────────────────────────────────
Tests de integración para database/crud_operations.py.

Requiere PostgreSQL corriendo con el schema aplicado.
Cada test usa savepoints para no dejar datos sucios.

Ejecutar:
  pytest database/tests/crud_operations_test.py -v
"""

import pytest

from database.migration.db import get_conn, Operations, check_connection
from database.crud_operations import (
    Collections, Documents, Images, HTR, GroundTruth, Models
)


@pytest.fixture(scope="module")
def db_available():
    if not check_connection():
        pytest.skip("BD no disponible. Ejecuta htr_db_start primero.")


@pytest.fixture
def conn(db_available):
    with get_conn() as c:
        c.cursor().execute("SAVEPOINT test_start")
        yield c
        c.cursor().execute("ROLLBACK TO SAVEPOINT test_start")


class TestCollections:
    def test_create_returns_id(self, conn):
        collection_id = Collections.create(
            conn, collection_name="test_collection_crud", collection_type="AGN"
        )
        assert isinstance(collection_id, int) and collection_id > 0

    def test_create_registers_operation(self, conn):
        collection_id = Collections.create(
            conn, collection_name="test_col_op", collection_type="AGN"
        )
        assert Operations.has_completed(conn, "collection_registered", "collection", collection_id)

    def test_get_by_id(self, conn):
        collection_id = Collections.create(
            conn, collection_name="test_get_col", collection_type="AGI"
        )
        result = Collections.get_by_id(conn, collection_id)
        assert result is not None
        assert result["collection_name"] == "test_get_col"
        assert result["collection_type"] == "AGI"

    def test_get_by_id_nonexistent(self, conn):
        assert Collections.get_by_id(conn, -999) is None

    def test_update_status(self, conn):
        collection_id = Collections.create(
            conn, collection_name="test_status_col", collection_type="AGN"
        )
        Collections.update_status(conn, collection_id, "archived")
        result = Collections.get_by_id(conn, collection_id)
        assert result["collection_status"] == "archived"


class TestDocuments:
    @pytest.fixture
    def collection_id(self, conn):
        return Collections.create(conn, collection_name="test_docs_col", collection_type="AGN")

    def test_create_returns_id(self, conn, collection_id):
        doc_id = Documents.create(
            conn, collection_id=collection_id, document_filename="expediente_001"
        )
        assert isinstance(doc_id, int) and doc_id > 0

    def test_create_registers_operation(self, conn, collection_id):
        doc_id = Documents.create(
            conn, collection_id=collection_id, document_filename="expediente_op"
        )
        assert Operations.has_completed(conn, "document_registered", "document", doc_id)

    def test_initial_status_is_new_untouched(self, conn, collection_id):
        doc_id = Documents.create(
            conn, collection_id=collection_id, document_filename="doc_status"
        )
        result = Documents.get_by_id(conn, doc_id)
        assert result["document_status"] == "new_untouched"

    def test_get_by_collection(self, conn, collection_id):
        Documents.create(conn, collection_id=collection_id, document_filename="doc_a")
        Documents.create(conn, collection_id=collection_id, document_filename="doc_b")
        docs = Documents.get_by_collection(conn, collection_id)
        assert len(docs) >= 2

    def test_update_status(self, conn, collection_id):
        doc_id = Documents.create(
            conn, collection_id=collection_id, document_filename="doc_upd"
        )
        Documents.update_status(conn, doc_id, "new_pages_processed")
        result = Documents.get_by_id(conn, doc_id)
        assert result["document_status"] == "new_pages_processed"


class TestImages:
    @pytest.fixture
    def document_id(self, conn):
        col_id = Collections.create(conn, collection_name="test_imgs_col", collection_type="AGN")
        return Documents.create(conn, collection_id=col_id, document_filename="doc_imgs")

    def test_create_original(self, conn, document_id):
        image_id = Images.create(
            conn, document_id=document_id,
            image_filename="pag_001.jpg", image_type="original", page_number=1
        )
        assert isinstance(image_id, int) and image_id > 0

    def test_create_processed_links_to_original(self, conn, document_id):
        orig_id = Images.create(
            conn, document_id=document_id,
            image_filename="pag_001.jpg", image_type="original"
        )
        proc_id = Images.create(
            conn, document_id=document_id,
            image_filename="pag_001_proc.jpg",
            image_type="processed", parent_image_id=orig_id
        )
        result = Images.get_by_id(conn, proc_id)
        assert result["parent_image_id"] == orig_id

    def test_registers_image_registered_operation(self, conn, document_id):
        image_id = Images.create(
            conn, document_id=document_id,
            image_filename="pag_002.jpg", image_type="original"
        )
        assert Operations.has_completed(conn, "image_registered", "image", image_id)

    def test_get_by_document_filtered(self, conn, document_id):
        Images.create(conn, document_id=document_id, image_filename="orig.jpg", image_type="original")
        Images.create(conn, document_id=document_id, image_filename="proc.jpg", image_type="processed")
        originals = Images.get_by_document(conn, document_id, image_type="original")
        assert all(img["image_type"] == "original" for img in originals)


class TestHTR:
    @pytest.fixture
    def image_id(self, conn):
        col_id = Collections.create(conn, collection_name="test_htr_col", collection_type="AGN")
        doc_id = Documents.create(conn, collection_id=col_id, document_filename="doc_htr")
        return Images.create(conn, document_id=doc_id, image_filename="pag.jpg", image_type="original")

    def test_create_returns_id(self, conn, image_id):
        htr_id = HTR.create(
            conn, image_id=image_id,
            htr_path="data_ingestion/transkribús/col/doc/pag_htr.txt"
        )
        assert isinstance(htr_id, int) and htr_id > 0

    def test_registers_htr_available(self, conn, image_id):
        htr_id = HTR.create(
            conn, image_id=image_id, htr_path="path/htr.txt"
        )
        assert Operations.has_completed(conn, "htr_available", "htr", htr_id)

    def test_get_by_image(self, conn, image_id):
        HTR.create(conn, image_id=image_id, htr_path="path/htr.txt")
        result = HTR.get_by_image(conn, image_id)
        assert result is not None
        assert result["image_id"] == image_id


class TestModels:
    def test_create_and_get(self, conn):
        model_id = Models.create(
            conn, model_name="test_classifier",
            model_version="1.0",
            model_local_path="data_ingestion/models/test_v1"
        )
        result = Models.get_by_id(conn, model_id)
        assert result is not None
        assert result["model_name"] == "test_classifier"

    def test_registers_model_registered(self, conn):
        model_id = Models.create(conn, model_name="test_model_op", model_version="1.0")
        assert Operations.has_completed(conn, "model_registered", "model", model_id)

    def test_get_by_name(self, conn):
        Models.create(conn, model_name="spanish_historical_clean_test", model_version="2.0")
        result = Models.get_by_name(conn, "spanish_historical_clean_test")
        assert result is not None
