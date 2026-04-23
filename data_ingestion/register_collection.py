"""
data_ingestion/register_collection.py
──────────────────────────────────────
Registra una colección en la BD recorriendo su estructura de directorios.

Estructura esperada en --source-dir:
  nombre_colección/
    nombre_colección_metadata.csv   ← metadatos de todos los documentos
    documento_001/                  ← subdirectorio = documento
      imagen_001.jpg                ← imagen = página del documento
      imagen_002.jpg
    documento_002/
      ...

Flujo:
  1. Insertar en public.collections → operación collection_registered
  2. Leer CSV de metadatos si existe
  3. Para cada subdirectorio: insertar en public.documents → operación document_registered
  4. Para cada imagen: insertar en public.images → operación image_registered
  5. Imprimir resumen

Uso:
  python register_collection.py \\
    --name "AGN_Flotas_Serie_1" \\
    --collection-type AGN \\
    --source-dir ./data_ingestion/raw_collections_images/AGN_Flotas_Serie_1

  htr_register_collection
"""

import argparse
import csv
from pathlib import Path
from typing import Optional

from database.migration.db import get_conn
from database.crud_operations import Collections, Documents, Images

IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".tif", ".tiff", ".bmp"}


def _read_metadata_csv(csv_path: Path) -> dict[str, dict]:
    """
    Lee el CSV de metadatos de la colección.
    Devuelve {document_filename: {columna: valor}}.
    La primera columna se usa como clave del documento.
    """
    if not csv_path.exists():
        return {}
    metadata = {}
    with csv_path.open(encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            key = list(row.values())[0].strip()
            metadata[key] = dict(row)
    return metadata


def register_collection(
    source_dir: Path,
    collection_name: str,
    collection_type: str = "AGN",
    collection_url: Optional[str] = None,
    collaborator_id: Optional[int] = None,
) -> dict:
    """
    Registra una colección completa desde un directorio local.
    Devuelve un resumen con los IDs asignados.
    """
    source_dir = source_dir.resolve()
    if not source_dir.is_dir():
        raise ValueError(f"El directorio no existe: {source_dir}")

    csv_candidates = list(source_dir.glob("*_metadata.csv"))
    metadata_by_document: dict[str, dict] = {}
    metadata_csv_path = None
    if csv_candidates:
        metadata_csv_path = csv_candidates[0]
        metadata_by_document = _read_metadata_csv(metadata_csv_path)
        print(f"  ✓ CSV de metadatos: {metadata_csv_path.name} "
              f"({len(metadata_by_document)} registros)")
    else:
        print("  ⚠ No se encontró CSV de metadatos.")

    summary = {
        "collection_id": None,
        "collection_name": collection_name,
        "n_documents": 0,
        "n_images": 0,
        "documents": [],
    }

    with get_conn() as conn:
        collection_id = Collections.create(
            conn,
            collection_name=collection_name,
            collection_type=collection_type,
            collection_path=str(source_dir),
            collection_url=collection_url,
            metadata_csv_path=str(metadata_csv_path) if metadata_csv_path else None,
            collaborator_id=collaborator_id,
        )
        summary["collection_id"] = collection_id
        print(f"  ✓ Colección registrada: id={collection_id}")

        document_dirs = sorted(
            d for d in source_dir.iterdir() if d.is_dir()
        )
        if not document_dirs:
            print("  ⚠ No se encontraron subdirectorios de documentos.")

        for document_dir in document_dirs:
            doc_filename = document_dir.name
            doc_metadata = metadata_by_document.get(doc_filename, {})
            detail = None
            if doc_metadata:
                detail = "; ".join(
                    f"{k}={v}" for k, v in list(doc_metadata.items())[:3]
                )

            document_id = Documents.create(
                conn,
                collection_id=collection_id,
                document_filename=doc_filename,
                document_path=str(document_dir),
                detail=detail,
                collaborator_id=collaborator_id,
            )

            doc_info = {
                "document_id": document_id,
                "document_filename": doc_filename,
                "n_images": 0,
            }

            image_files = sorted(
                f for f in document_dir.iterdir()
                if f.is_file() and f.suffix.lower() in IMAGE_EXTENSIONS
            )

            for page_number, image_file in enumerate(image_files, start=1):
                Images.create(
                    conn,
                    document_id=document_id,
                    image_filename=image_file.name,
                    image_path=str(image_file),
                    image_type="original",
                    page_number=page_number,
                    collaborator_id=collaborator_id,
                )
                doc_info["n_images"] += 1
                summary["n_images"] += 1

            summary["documents"].append(doc_info)
            summary["n_documents"] += 1
            print(f"    {doc_filename}: {doc_info['n_images']} imágenes")

    return summary


def main():
    parser = argparse.ArgumentParser(
        description="Registrar una colección de documentos históricos en la BD."
    )
    parser.add_argument("--name", required=True,
                        help="Nombre de la colección.")
    parser.add_argument("--collection-type", default="AGN",
                        choices=["AGN", "AGI", "corpus_local", "ground_truth_collection"])
    parser.add_argument("--source-dir", type=Path, required=True,
                        help="Directorio raíz con subcarpetas de documentos.")
    parser.add_argument("--url", default=None)
    parser.add_argument("--collaborator-id", type=int, default=None)
    args = parser.parse_args()

    print(f"▶ Registrando colección '{args.name}'...")
    print(f"  Fuente : {args.source_dir}")
    print(f"  Tipo   : {args.collection_type}")

    summary = register_collection(
        source_dir=args.source_dir,
        collection_name=args.name,
        collection_type=args.collection_type,
        collection_url=args.url,
        collaborator_id=args.collaborator_id,
    )

    print()
    print("═" * 50)
    print(f"  collection_id : {summary['collection_id']}")
    print(f"  Documentos    : {summary['n_documents']}")
    print(f"  Imágenes      : {summary['n_images']}")
    print("═" * 50)


if __name__ == "__main__":
    main()
