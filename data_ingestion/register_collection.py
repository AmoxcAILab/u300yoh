"""
data_ingestion/register_collection.py
──────────────────────────────────────
Registra una colección y sus documentos desde archivos .metadata.

Estructura de archivos esperada:
  {metadata_root}/
    {collection}.metadata              ← metadatos de la colección
    documents/{collection}/            ← metadatos de documentos
      **/*.metadata                    ← un archivo por documento

Formato de {collection}.metadata:
  collection_name                : Marina
  collection_type                : AGN
  collection_status              : new
  collection_url                 :
  collection_archival_institution: Archivo General de la Nación

Formato de {document}.metadata:
  document_name             : AGN_Marina_v001-1_exp001
  document_status           : new
  document_archive          : Archivo General de la Nación
  document_Fondo            : Marina
  document_Notas            : Las fojas 4 y 5 están en blanco.  ← se crea como nota
  ...

Flujo:
  1. Parsear {collection}.metadata → INSERT en collections → collection_registered
  2. Si collection_Notas → crear nota vinculada a la colección
  3. Para cada {document}.metadata:
     a. Extraer document_Notas (si existe)
     b. INSERT en documents con todos los campos archivísticos → document_registered
     c. Si había document_Notas → crear nota vinculada al documento

Uso:
  python data_ingestion/register_collection.py \\
    --collection-metadata data_ingestion/metadata/collections/AGN_marina.metadata

  htr_register_collection \\
    --collection-metadata data_ingestion/metadata/collections/AGN_marina.metadata
"""

import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import argparse
from typing import Optional

from database.migration.db import get_conn, Operations, resolve_collaborator_id
from database.crud_operations import Collections, Documents, Notes


# Campos del .metadata de colección que se usan para el INSERT o se ignoran.
# Todo lo demás se descarta silenciosamente.
_COLLECTION_KNOWN = {
    "collection_name",
    "collection_type",
    "collection_status",
    "collection_path",
    "collection_url",
    "collection_archival_institution",
}

# Campos del .metadata de documento que tienen tratamiento especial.
_DOCUMENT_SKIP = {
    "document_id",        # generado por la BD
    "collection_id",      # se pasa en tiempo de ejecución
    "document_status_id", # se resuelve desde document_status
}
_DOCUMENT_SPECIAL = {
    "document_name",
    "document_status",
    "document_path",
    "document_url",
    "document_Notas",   # se crea como nota, no se inserta en documents
}


def parse_metadata(path: Path) -> dict[str, Optional[str]]:
    """
    Parsea un archivo .metadata de formato 'clave : valor'.
    Los valores vacíos se devuelven como None.
    Ignora líneas sin ':'.
    """
    fields: dict[str, Optional[str]] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if ":" not in line:
            continue
        key, _, value = line.partition(":")
        key = key.strip()
        value = value.strip() or None
        if key:
            fields[key] = value
    return fields


def register_collection(
    collection_metadata: Path,
    collaborator_id: Optional[str] = None,
) -> dict:
    """
    Registra una colección completa en la BD desde sus archivos .metadata.
    Devuelve un resumen con los IDs asignados y conteos.
    """
    collection_metadata = collection_metadata.resolve()
    if not collection_metadata.exists():
        raise FileNotFoundError(f"Archivo no encontrado: {collection_metadata}")

    collection_name_from_stem = collection_metadata.stem  # e.g. "AGN_marina"
    docs_dir = collection_metadata.parent / "documents" / collection_name_from_stem

    # ── 1. Parsear metadatos de colección ─────────────────────────────────
    col_fields = parse_metadata(collection_metadata)

    collection_name = col_fields.get("collection_name") or collection_name_from_stem
    collection_type = col_fields.get("collection_type") or "AGN"
    collection_status = col_fields.get("collection_status") or "new"
    collection_path = col_fields.get("collection_path")
    collection_url = col_fields.get("collection_url")
    archival_institution = col_fields.get("collection_archival_institution")
    collection_notes = col_fields.get("collection_Notas")

    summary = {
        "collection_id":   None,
        "collection_name": collection_name,
        "n_documents":     0,
        "n_notes":         0,
        "errors":          [],
    }

    with get_conn() as conn:
        collaborator_id = resolve_collaborator_id(conn, collaborator_id)

        # ── 2. Registrar colección ─────────────────────────────────────────
        collection_id = Collections.create(
            conn,
            collection_name=collection_name,
            collection_type=collection_type,
            collection_status=collection_status,
            collection_path=collection_path,
            collection_url=collection_url,
            archival_institution=archival_institution,
            collaborator_id=collaborator_id,
        )
        summary["collection_id"] = str(collection_id)
        print(f"  ✓ Colección registrada: {collection_name} → {collection_id}")

        # ── 3. Nota de colección (si existe) ──────────────────────────────
        if collection_notes:
            note_id = Notes.create(conn, collection_notes)
            Notes.link_to_collection(conn, note_id, collection_id)
            op_id = Operations.record(conn, "note_created", collaborator_id)
            Notes.link_to_operation(conn, note_id, op_id)
            summary["n_notes"] += 1
            print(f"    ✓ Nota de colección registrada")

        # ── 4. Documentos ─────────────────────────────────────────────────
        if not docs_dir.exists():
            print(f"  ⚠ Directorio de documentos no encontrado: {docs_dir}")
            return summary

        doc_files = sorted(docs_dir.rglob("*.metadata"))
        if not doc_files:
            print(f"  ⚠ No se encontraron archivos .metadata en {docs_dir}")
            return summary

        print(f"  → {len(doc_files)} documentos encontrados")

        for doc_meta in doc_files:
            try:
                doc_fields = parse_metadata(doc_meta)

                # Extraer campos especiales
                document_name   = doc_fields.pop("document_name", None) or doc_meta.stem
                document_status = doc_fields.pop("document_status", None) or "new"
                document_path   = doc_fields.pop("document_path", None)
                document_url    = doc_fields.pop("document_url", None)
                doc_notes       = doc_fields.pop("document_Notas", None)

                # Eliminar campos que la BD genera o que no corresponden a documents
                for skip in _DOCUMENT_SKIP:
                    doc_fields.pop(skip, None)

                # Insertar documento con todos los campos archivísticos restantes
                document_id = Documents.create(
                    conn,
                    collection_id=collection_id,
                    document_name=document_name,
                    document_status=document_status,
                    document_path=document_path,
                    document_url=document_url,
                    collaborator_id=collaborator_id,
                    **doc_fields,
                )
                summary["n_documents"] += 1
                print(f"    ✓ {document_name}")

                # Nota del documento (si existe)
                if doc_notes:
                    note_id = Notes.create(conn, doc_notes)
                    Notes.link_to_document(conn, note_id, document_id)
                    op_id = Operations.record(conn, "note_created", collaborator_id)
                    Notes.link_to_operation(conn, note_id, op_id)
                    summary["n_notes"] += 1

            except Exception as exc:
                msg = f"ERR {doc_meta.name}: {exc}"
                print(f"    ✗ {msg}")
                summary["errors"].append(msg)

    return summary


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Registrar colección y documentos desde archivos .metadata."
    )
    parser.add_argument(
        "--collection-metadata",
        type=Path,
        required=True,
        help="Ruta al archivo {collection}.metadata (p.ej. data_ingestion/metadata/collections/AGN_marina.metadata)",
    )
    parser.add_argument(
        "--collaborator-id",
        default=None,
        help="UUID del colaborador (default: $HTR_COLLABORATOR_ID o $USER)",
    )
    args = parser.parse_args()

    print(f"▶ Registrando desde: {args.collection_metadata}")

    summary = register_collection(
        collection_metadata=args.collection_metadata,
        collaborator_id=args.collaborator_id,
    )

    print()
    print("═" * 55)
    print(f"  collection_id : {summary['collection_id']}")
    print(f"  Documentos    : {summary['n_documents']}")
    print(f"  Notas         : {summary['n_notes']}")
    if summary["errors"]:
        print(f"  Errores       : {len(summary['errors'])}")
        for e in summary["errors"]:
            print(f"    - {e}")
    print("═" * 55)


if __name__ == "__main__":
    main()
