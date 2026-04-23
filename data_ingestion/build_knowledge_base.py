"""
data_ingestion/build_knowledge_base.py
────────────────────────────────────────
Construye la base de conocimiento vectorial (RAG) desde cuatro fuentes:

  1. abbreviation   — public.abbreviations + public.expansions
  2. entity         — public.entities (solo verified=true)
  3. error_pattern  — public.errors + public.corrections + public.patterns
  4. document_knowledge — archivos en data_ingestion/knowledge_bases/

Los embeddings se generan con el modelo configurado en HTR_EMBEDDING_MODEL
(default: 'sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2').

Uso:
  python build_knowledge_base.py [--types abbreviation entity error_pattern document_knowledge]
  htr_knowledge_base_rebuild

Variables de entorno:
  HTR_EMBEDDING_MODEL  nombre del modelo de sentence-transformers (default arriba)
  HTR_KB_BATCH_SIZE    tamaño de lote para embeddings (default: 64)
"""

import argparse
import os
from pathlib import Path
from typing import Optional

from database.migration.db import get_conn, Operations

KNOWLEDGE_BASES_DIR = Path(__file__).parent / "knowledge_bases"

# Extensiones de documentos de conocimiento
DOCUMENT_EXTENSIONS = {".txt", ".md", ".csv"}

DEFAULT_EMBEDDING_MODEL = "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
DEFAULT_BATCH_SIZE = 64


def _get_embedding_model():
    """
    Carga el modelo de embeddings. Devuelve None si no está disponible.
    El modelo se selecciona desde HTR_EMBEDDING_MODEL o el default.
    """
    model_name = os.environ.get("HTR_EMBEDDING_MODEL", DEFAULT_EMBEDDING_MODEL)
    try:
        from sentence_transformers import SentenceTransformer
        print(f"  ▶ Cargando modelo de embeddings: {model_name}")
        model = SentenceTransformer(model_name)
        print(f"  ✓ Modelo cargado.")
        return model
    except ImportError:
        print("  ⚠ sentence_transformers no disponible. "
              "Los embeddings se guardarán como NULL.")
        return None


def _embed_texts(model, texts: list[str], batch_size: int = DEFAULT_BATCH_SIZE) -> list:
    """Genera embeddings en lotes. Devuelve lista de listas de floats o None si no hay modelo."""
    if model is None:
        return [None] * len(texts)
    batch_size = int(os.environ.get("HTR_KB_BATCH_SIZE", batch_size))
    embeddings = model.encode(texts, batch_size=batch_size, show_progress_bar=True)
    return embeddings.tolist()


def _clear_kb_type(conn, knowledge_base_type: str) -> None:
    """Elimina entradas existentes de un tipo para reconstruir desde cero."""
    cur = conn.cursor()
    cur.execute(
        "DELETE FROM rag.knowledge_base WHERE knowledge_base_type = %(t)s",
        {"t": knowledge_base_type},
    )
    deleted = cur.rowcount
    print(f"  ✓ Eliminadas {deleted} entradas anteriores de tipo '{knowledge_base_type}'")


def _insert_kb_entries(conn, entries: list[dict]) -> int:
    """
    Inserta entradas en rag.knowledge_base.
    Cada entry: {knowledge_base_type, content, embedding, metadata, verified, ...}
    Devuelve N insertados.
    """
    if not entries:
        return 0
    cur = conn.cursor()
    for entry in entries:
        embedding = entry.get("embedding")
        # psycopg2 necesita el vector como string '[x,y,...]'
        embedding_str = None
        if embedding is not None:
            embedding_str = "[" + ",".join(str(v) for v in embedding) + "]"

        cur.execute(
            """
            INSERT INTO rag.knowledge_base (
                knowledge_base_type, abbreviation_id, expansion_id, entity_id,
                content, embedding, metadata, verified
            ) VALUES (
                %(kb_type)s, %(abbr_id)s, %(exp_id)s, %(ent_id)s,
                %(content)s, %(embedding)s::vector, %(metadata)s, %(verified)s
            )
            """,
            {
                "kb_type":   entry["knowledge_base_type"],
                "abbr_id":   entry.get("abbreviation_id"),
                "exp_id":    entry.get("expansion_id"),
                "ent_id":    entry.get("entity_id"),
                "content":   entry["content"],
                "embedding": embedding_str,
                "metadata":  entry.get("metadata"),
                "verified":  entry.get("verified", False),
            },
        )
    return len(entries)


# ──────────────────────────────────────────────────────────────
# FUENTE 1: ABREVIATURAS Y EXPANSIONES
# ──────────────────────────────────────────────────────────────

def build_abbreviations(conn, model) -> int:
    """
    Indexa pares (abreviatura, expansión) desde public.abbreviations + public.expansions.
    El texto del embedding es: "Abreviatura: {abbr} → Expansión: {exp} (tipo: {type})"
    """
    print("  ▶ Indexando abreviaturas y expansiones...")
    _clear_kb_type(conn, "abbreviation")

    cur = conn.cursor()
    cur.execute(
        """
        SELECT
            a.abbreviation_id,
            a.abbreviation,
            et.expansion_type,
            array_agg(e.expansion_id ORDER BY e.expansion_id) AS expansion_ids,
            array_agg(e.expansion ORDER BY e.expansion_id) AS expansion_texts
        FROM public.abbreviations a
        LEFT JOIN public.expansion_type et ON a.expansion_type_id = et.expansion_type_id
        LEFT JOIN public.abbreviations_expansions ae ON a.abbreviation_id = ae.abbreviation_id
        LEFT JOIN public.expansions e ON ae.expansion_id = e.expansion_id
        GROUP BY a.abbreviation_id, a.abbreviation, et.expansion_type
        ORDER BY a.abbreviation
        """
    )
    rows = cur.fetchall()

    entries = []
    for row in rows:
        abbr = row["abbreviation"]
        expansion_type = row["expansion_type"] or "unknown"
        expansions = [e for e in (row["expansion_texts"] or []) if e]

        if not expansions:
            content = f"Abreviatura: {abbr} (sin expansión registrada)"
            entries.append({
                "knowledge_base_type": "abbreviation",
                "abbreviation_id": row["abbreviation_id"],
                "content": content,
                "verified": False,
                "metadata": f'{{"abbreviation": "{abbr}", "expansion_type": "{expansion_type}"}}',
            })
        else:
            for exp_id, exp_text in zip(row["expansion_ids"], expansions):
                content = (
                    f"Abreviatura: {abbr} → Expansión: {exp_text} "
                    f"(tipo: {expansion_type})"
                )
                entries.append({
                    "knowledge_base_type": "abbreviation",
                    "abbreviation_id": row["abbreviation_id"],
                    "expansion_id": exp_id,
                    "content": content,
                    "verified": expansion_type in ("certain", "probable"),
                    "metadata": (
                        f'{{"abbreviation": "{abbr}", '
                        f'"expansion": "{exp_text}", '
                        f'"expansion_type": "{expansion_type}"}}'
                    ),
                })

    if entries:
        texts = [e["content"] for e in entries]
        embeddings = _embed_texts(model, texts)
        for entry, emb in zip(entries, embeddings):
            entry["embedding"] = emb

    n = _insert_kb_entries(conn, entries)
    print(f"  ✓ {n} entradas de abreviaturas indexadas.")
    return n


# ──────────────────────────────────────────────────────────────
# FUENTE 2: ENTIDADES VERIFICADAS
# ──────────────────────────────────────────────────────────────

def build_entities(conn, model) -> int:
    """
    Indexa entidades verificadas desde public.entities.
    Solo entidades con verified=true.
    """
    print("  ▶ Indexando entidades verificadas...")
    _clear_kb_type(conn, "entity")

    cur = conn.cursor()
    cur.execute(
        """
        SELECT
            e.entity_id,
            e.entity_name,
            e.canonical_form,
            e.verified,
            array_agg(DISTINCT ety.entity_type) AS entity_types
        FROM public.entities e
        LEFT JOIN public.entities_entity_types eet ON e.entity_id = eet.entity_id
        LEFT JOIN public.entity_types ety ON eet.entity_type_id = ety.entity_type_id
        WHERE e.verified = TRUE
        GROUP BY e.entity_id, e.entity_name, e.canonical_form, e.verified
        ORDER BY e.entity_name
        """
    )
    rows = cur.fetchall()

    entries = []
    for row in rows:
        entity_types = [t for t in (row["entity_types"] or []) if t]
        types_str = ", ".join(entity_types) if entity_types else "desconocido"
        canonical = row["canonical_form"] or row["entity_name"]
        content = (
            f"Entidad histórica: {row['entity_name']} "
            f"(forma canónica: {canonical}, tipo: {types_str})"
        )
        entries.append({
            "knowledge_base_type": "entity",
            "entity_id": row["entity_id"],
            "content": content,
            "verified": True,
            "metadata": (
                f'{{"entity_name": "{row["entity_name"]}", '
                f'"canonical_form": "{canonical}", '
                f'"entity_types": {entity_types}}}'
            ),
        })

    if entries:
        texts = [e["content"] for e in entries]
        embeddings = _embed_texts(model, texts)
        for entry, emb in zip(entries, embeddings):
            entry["embedding"] = emb

    n = _insert_kb_entries(conn, entries)
    print(f"  ✓ {n} entidades indexadas.")
    return n


# ──────────────────────────────────────────────────────────────
# FUENTE 3: PATRONES DE ERROR Y CORRECCIONES
# ──────────────────────────────────────────────────────────────

def build_error_patterns(conn, model) -> int:
    """
    Indexa pares (error HTR, corrección) y patrones desde la BD.
    """
    print("  ▶ Indexando patrones de error y correcciones...")
    _clear_kb_type(conn, "error_pattern")

    cur = conn.cursor()
    # Errores con correcciones
    cur.execute(
        """
        SELECT
            er.error_id,
            er.htr_word,
            er.ground_truth_word,
            er.context,
            ert.error_type,
            c.corrected_word,
            c.score
        FROM public.errors er
        LEFT JOIN public.error_type ert ON er.error_type_id = ert.error_type_id
        LEFT JOIN public.corrections c ON er.error_id = c.error_id
        WHERE er.ground_truth_word IS NOT NULL
          AND er.ground_truth_word != ''
        ORDER BY er.error_id
        LIMIT 10000
        """
    )
    error_rows = cur.fetchall()

    # Patrones
    cur.execute(
        """
        SELECT p.pattern_id, p.htr, p.ground_truth, pt.pattern_type, pt.rules
        FROM public.patterns p
        LEFT JOIN public.pattern_types pt ON p.pattern_type_id = pt.pattern_type_id
        ORDER BY p.pattern_id
        LIMIT 5000
        """
    )
    pattern_rows = cur.fetchall()

    entries = []
    for row in error_rows:
        correction = row["corrected_word"] or row["ground_truth_word"]
        context_snippet = (row["context"] or "")[:100]
        content = (
            f"Error HTR: '{row['htr_word']}' → Corrección: '{correction}' "
            f"(tipo: {row['error_type'] or 'desconocido'}, "
            f"contexto: {context_snippet})"
        )
        entries.append({
            "knowledge_base_type": "error_pattern",
            "content": content,
            "verified": row["score"] is not None and row["score"] >= 4,
            "metadata": (
                f'{{"htr_word": "{row["htr_word"]}", '
                f'"corrected_word": "{correction}", '
                f'"error_type": "{row["error_type"] or ""}"}}'
            ),
        })

    for row in pattern_rows:
        content = (
            f"Patrón {row['pattern_type'] or 'general'}: "
            f"HTR '{row['htr']}' → Ground truth '{row['ground_truth']}'"
        )
        if row["rules"]:
            content += f" (regla: {row['rules'][:80]})"
        entries.append({
            "knowledge_base_type": "error_pattern",
            "content": content,
            "verified": False,
            "metadata": (
                f'{{"pattern_type": "{row["pattern_type"] or "general"}", '
                f'"htr": "{row["htr"]}", '
                f'"ground_truth": "{row["ground_truth"]}"}}'
            ),
        })

    if entries:
        texts = [e["content"] for e in entries]
        embeddings = _embed_texts(model, texts)
        for entry, emb in zip(entries, embeddings):
            entry["embedding"] = emb

    n = _insert_kb_entries(conn, entries)
    print(f"  ✓ {n} patrones de error indexados.")
    return n


# ──────────────────────────────────────────────────────────────
# FUENTE 4: DOCUMENTOS Y DICCIONARIOS DE CONOCIMIENTO
# ──────────────────────────────────────────────────────────────

def build_document_knowledge(conn, model) -> int:
    """
    Indexa archivos de texto desde data_ingestion/knowledge_bases/.
    Divide archivos largos en fragmentos de ~500 palabras.
    """
    print(f"  ▶ Indexando documentos de knowledge_bases ({KNOWLEDGE_BASES_DIR})...")
    _clear_kb_type(conn, "document_knowledge")

    if not KNOWLEDGE_BASES_DIR.exists():
        print(f"  ⚠ Directorio {KNOWLEDGE_BASES_DIR} no encontrado. Omitiendo.")
        return 0

    entries = []
    for file_path in sorted(KNOWLEDGE_BASES_DIR.rglob("*")):
        if file_path.suffix.lower() not in DOCUMENT_EXTENSIONS:
            continue
        if not file_path.is_file():
            continue

        try:
            text = file_path.read_text(encoding="utf-8", errors="replace")
        except Exception as e:
            print(f"    ⚠ Error leyendo {file_path.name}: {e}")
            continue

        # Dividir en fragmentos de ~500 palabras
        words = text.split()
        chunk_size = 500
        chunks = [
            " ".join(words[i:i + chunk_size])
            for i in range(0, len(words), chunk_size)
        ]

        for chunk_idx, chunk in enumerate(chunks):
            if len(chunk.strip()) < 20:
                continue
            relative_path = file_path.relative_to(KNOWLEDGE_BASES_DIR)
            content = f"[{relative_path}] {chunk}"
            entries.append({
                "knowledge_base_type": "document_knowledge",
                "content": content,
                "verified": True,
                "metadata": (
                    f'{{"file": "{relative_path}", '
                    f'"chunk": {chunk_idx}, '
                    f'"total_chunks": {len(chunks)}}}'
                ),
            })

        print(f"    {file_path.name}: {len(chunks)} fragmentos")

    if entries:
        texts = [e["content"] for e in entries]
        embeddings = _embed_texts(model, texts)
        for entry, emb in zip(entries, embeddings):
            entry["embedding"] = emb

    n = _insert_kb_entries(conn, entries)
    print(f"  ✓ {n} fragmentos de documentos indexados.")
    return n


# ──────────────────────────────────────────────────────────────
# FUNCIÓN PRINCIPAL
# ──────────────────────────────────────────────────────────────

def build_knowledge_base(
    types: Optional[list[str]] = None,
    collaborator_id: Optional[int] = None,
) -> dict[str, int]:
    """
    Reconstruye la knowledge base para los tipos especificados.
    Si types=None, reconstruye todos los tipos.
    Devuelve {tipo: n_entradas}.
    """
    all_types = ["abbreviation", "entity", "error_pattern", "document_knowledge"]
    types_to_build = types or all_types

    unknown = set(types_to_build) - set(all_types)
    if unknown:
        raise ValueError(f"Tipos desconocidos: {unknown}. Opciones: {all_types}")

    model = _get_embedding_model()
    summary: dict[str, int] = {}

    with get_conn() as conn:
        for kb_type in types_to_build:
            if kb_type == "abbreviation":
                summary["abbreviation"] = build_abbreviations(conn, model)
            elif kb_type == "entity":
                summary["entity"] = build_entities(conn, model)
            elif kb_type == "error_pattern":
                summary["error_pattern"] = build_error_patterns(conn, model)
            elif kb_type == "document_knowledge":
                summary["document_knowledge"] = build_document_knowledge(conn, model)

        Operations.record(
            conn,
            operation_type="knowledge_base_rebuilt",
            collaborator_id=collaborator_id,
        )

    return summary


def main():
    parser = argparse.ArgumentParser(
        description="Reconstruir la base de conocimiento vectorial (RAG)."
    )
    parser.add_argument(
        "--types", nargs="*",
        choices=["abbreviation", "entity", "error_pattern", "document_knowledge"],
        default=None,
        help="Tipos a reconstruir (default: todos)."
    )
    parser.add_argument(
        "--collaborator-id", type=int, default=None
    )
    args = parser.parse_args()

    print("▶ Reconstruyendo base de conocimiento RAG...")
    if args.types:
        print(f"  Tipos: {args.types}")
    else:
        print("  Tipos: todos")

    summary = build_knowledge_base(
        types=args.types,
        collaborator_id=args.collaborator_id,
    )

    print()
    print("═" * 50)
    print("  Knowledge base reconstruida")
    for kb_type, count in summary.items():
        print(f"  {kb_type:<25}: {count} entradas")
    print(f"  Total: {sum(summary.values())} entradas")
    print("═" * 50)


if __name__ == "__main__":
    main()
