"""
data_ingestion/import_collection.py
────────────────────────────────────
Descarga o copia imágenes raw de una colección desde una fuente externa.

Las imágenes se guardan en:
  data_ingestion/raw_collections_images/{collection_name}/{document_name}/

Para cada imagen: inserta en public.images, vincula a public.documents,
registra la operación image_registered.
Registra images_downloaded sobre la colección al terminar.

Uso:
  python import_collection.py \\
    --collection-id 42 \\
    --source-dir /ruta/externa/AGN_Flotas_Serie_1

  htr_download_images
"""

import argparse
import shutil
from pathlib import Path
from typing import Optional

from database.migration.db import get_conn, Operations
from database.crud_operations import Collections, Documents, Images

IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".tif", ".tiff", ".bmp"}

# Directorio base para imágenes raw dentro del repo
RAW_IMAGES_BASE = Path(__file__).parent / "raw_collections_images"


def import_collection(
    collection_id: int,
    source_dir: Path,
    collaborator_id: Optional[int] = None,
) -> dict:
    """
    Importa imágenes de una fuente externa hacia raw_collections_images/.
    Registra cada imagen en la BD vinculada a su documento.
    Devuelve un resumen.
    """
    source_dir = source_dir.resolve()
    if not source_dir.is_dir():
        raise ValueError(f"El directorio fuente no existe: {source_dir}")

    with get_conn() as conn:
        collection = Collections.get_by_id(conn, collection_id)
        if collection is None:
            raise ValueError(f"Colección {collection_id} no encontrada en la BD.")

        collection_name = collection["collection_name"]
        documents = Documents.get_by_collection(conn, collection_id)
        documents_by_name = {d["document_filename"]: d for d in documents}

    destination_base = RAW_IMAGES_BASE / collection_name
    destination_base.mkdir(parents=True, exist_ok=True)

    summary = {
        "collection_id": collection_id,
        "collection_name": collection_name,
        "n_images_imported": 0,
        "n_documents_processed": 0,
        "not_found_in_db": [],
    }

    document_dirs = sorted(
        d for d in source_dir.iterdir() if d.is_dir()
    )

    with get_conn() as conn:
        for document_dir in document_dirs:
            doc_name = document_dir.name
            doc_record = documents_by_name.get(doc_name)

            if doc_record is None:
                print(f"  ⚠ Documento '{doc_name}' no está registrado en BD. Omitiendo.")
                summary["not_found_in_db"].append(doc_name)
                continue

            document_id = doc_record["document_id"]
            dest_document_dir = destination_base / doc_name
            dest_document_dir.mkdir(parents=True, exist_ok=True)

            image_files = sorted(
                f for f in document_dir.iterdir()
                if f.is_file() and f.suffix.lower() in IMAGE_EXTENSIONS
            )

            for page_number, image_file in enumerate(image_files, start=1):
                dest_path = dest_document_dir / image_file.name
                if not dest_path.exists():
                    shutil.copy2(image_file, dest_path)

                Images.create(
                    conn,
                    document_id=document_id,
                    image_filename=image_file.name,
                    image_path=str(dest_path),
                    image_type="original",
                    page_number=page_number,
                    collaborator_id=collaborator_id,
                )
                summary["n_images_imported"] += 1

            summary["n_documents_processed"] += 1
            print(f"    {doc_name}: {len(image_files)} imágenes importadas")

        Operations.record_and_link(
            conn,
            operation_type="images_downloaded",
            entity="collection",
            entity_id=collection_id,
            collaborator_id=collaborator_id,
        )

    return summary


def main():
    parser = argparse.ArgumentParser(
        description="Descargar/copiar imágenes raw de una colección."
    )
    parser.add_argument("--collection-id", type=int, required=True,
                        help="ID de la colección ya registrada en BD.")
    parser.add_argument("--source-dir", type=Path, required=True,
                        help="Directorio fuente con las imágenes.")
    parser.add_argument("--collaborator-id", type=int, default=None)
    args = parser.parse_args()

    print(f"▶ Importando imágenes para colección {args.collection_id}...")
    print(f"  Fuente: {args.source_dir}")

    summary = import_collection(
        collection_id=args.collection_id,
        source_dir=args.source_dir,
        collaborator_id=args.collaborator_id,
    )

    print()
    print("═" * 50)
    print(f"  Documentos procesados : {summary['n_documents_processed']}")
    print(f"  Imágenes importadas   : {summary['n_images_imported']}")
    if summary["not_found_in_db"]:
        print(f"  ⚠ No encontrados en BD: {summary['not_found_in_db']}")
    print(f"  Destino: {RAW_IMAGES_BASE / summary['collection_name']}")
    print("═" * 50)


if __name__ == "__main__":
    main()
