"""
Convierte los PDFs de AGN_marina a archivos .metadata para el pipeline de ingestión.

Uso:
    python data_ingestion/pdf_to_metadata.py

Entrada:  data_ingestion/metadata/collections/documents/AGN_marina/**/*.pdf
Salida:   data_ingestion/metadata/collections/AGN_marina/documentos/*.metadata
"""

import re
from pathlib import Path

import fitz  # pymupdf

# ---------------------------------------------------------------------------
# Mapeo de etiquetas PDF → campos .metadata
# ---------------------------------------------------------------------------

MONTHS = {
    "enero": "01", "febrero": "02", "marzo": "03", "abril": "04",
    "mayo": "05", "junio": "06", "julio": "07", "agosto": "08",
    "septiembre": "09", "octubre": "10", "noviembre": "11", "diciembre": "12",
}

# Etiquetas del PDF en el orden en que aparecen.
# El texto entre una etiqueta y la siguiente es el valor del campo.
PDF_LABELS = [
    "Fondo",
    "Unidad de instalación",
    "Expediente",
    "Nivel de descripción",
    "Volumen de la unidad de descripción",
    "Fechas",
    "Lugar de expedición",
    "Alcance y contenido",
    "Soporte",
    "Estado de conservación",
    "Notas",
]

# Patrón regex que une todas las etiquetas (incluyendo la versión partida con guión)
_LABEL_PATTERN = re.compile(
    r"(?:"
    + "|".join(
        re.escape(lbl).replace(r"ci", r"ció?n?")
        for lbl in PDF_LABELS
    )
    + r"|Volumen de la unidad de de-\s*scripci[oó]n)"
    , re.IGNORECASE
)

# Etiqueta normalizada (para el repr del PDF que puede tener caracteres mal codificados)
_LABEL_RE = re.compile(
    r"(Fondo"
    r"|Unidad de instalaci.n"
    r"|Expediente"
    r"|Nivel de descripci.n"
    r"|Volumen de la unidad de de-\s*scripci.n"
    r"|Fechas"
    r"|Lugar de expedici.n"
    r"|Alcance y contenido"
    r"|Soporte"
    r"|Estado de conservaci.n"
    r"|Notas)"
    r"(?=\n)",
    re.IGNORECASE,
)


def _normalize_label(raw: str) -> str:
    raw = raw.strip().lower()
    if raw.startswith("fondo"):
        return "Fondo"
    if raw.startswith("unidad de instalac"):
        return "Unidad de instalación"
    if raw == "expediente":
        return "Expediente"
    if raw.startswith("nivel de descrip"):
        return "Nivel de descripción"
    if raw.startswith("volumen de la unidad"):
        return "Volumen de la unidad de descripción"
    if raw == "fechas":
        return "Fechas"
    if raw.startswith("lugar de expedi"):
        return "Lugar de expedición"
    if raw.startswith("alcance y contenido"):
        return "Alcance y contenido"
    if raw == "soporte":
        return "Soporte"
    if raw.startswith("estado de conserva"):
        return "Estado de conservación"
    if raw == "notas":
        return "Notas"
    return raw


def extract_fields(pdf_path: Path) -> dict[str, str]:
    """Extrae el texto del PDF y devuelve un dict etiqueta → valor."""
    doc = fitz.open(pdf_path)
    text = doc[0].get_text()

    # Partir en líneas y eliminar cabecera + pie
    lines = text.splitlines()
    # Quitar "Repositorio Documental Digital", el título y "1 / 1"
    lines = [l for l in lines if l.strip() not in (
        "Repositorio Documental Digital", "1 / 1", ""
    ) and not re.match(r"Marina / Volumen .+ / Expediente .+", l.strip())]

    # Reconstruir texto limpio
    clean = "\n".join(lines)

    # Localizar posiciones de cada etiqueta conocida.
    # Guardamos (start, end, label) para saber exactamente dónde termina la etiqueta
    # — necesario cuando la etiqueta está partida con guión en varias líneas.
    segments: list[tuple[int, int, str]] = []
    for m in _LABEL_RE.finditer(clean):
        segments.append((m.start(), m.end(), _normalize_label(m.group())))

    if not segments:
        return {}

    fields: dict[str, str] = {}
    for i, (pos, end, label) in enumerate(segments):
        # El lookahead (?=\n) no consume el \n, así que m.end() apunta justo al \n.
        # El valor empieza en end + 1.
        value_start = end + 1
        value_end = segments[i + 1][0] if i + 1 < len(segments) else len(clean)
        value = clean[value_start:value_end].strip()
        # Colapsar saltos de línea internos del valor en un espacio
        value = re.sub(r"\s*\n\s*", " ", value)
        fields[label] = value

    return fields


def convert_date(raw: str) -> tuple[str, str]:
    """
    Convierte "1578/octubre/11" → ("11/10/1578", "1578").
    Para rangos "1639/julio/22-1640/febrero/27" → ("22/07/1639-27/02/1640", "1639").
    Devuelve (fecha_creacion, año_creacion).
    """
    raw = raw.strip()

    def _one(part: str) -> str:
        m = re.match(r"(\d{4})/(\w+)/(\d{1,2})", part.strip())
        if not m:
            return part.strip()
        year, month_name, day = m.group(1), m.group(2).lower(), m.group(3).zfill(2)
        month = MONTHS.get(month_name, "??")
        return f"{day}/{month}/{year}"

    if "-" in raw:
        # puede haber rangos: "1639/julio/22-1640/febrero/27"
        # el guión separa dos fechas YYYY/mes/DD
        parts = re.split(r"-(?=\d{4}/)", raw)
        fecha = "-".join(_one(p) for p in parts)
        year = re.match(r"(\d{4})", raw).group(1)
    else:
        fecha = _one(raw)
        m = re.match(r"(\d{4})", raw)
        year = m.group(1) if m else ""

    return fecha, year


def normalize_rango_fojas(raw: str) -> str:
    """Quita el prefijo 'Foja(s) ' del campo de rango."""
    return re.sub(r"^Fojas?\s+", "", raw.strip())


def build_metadata(pdf_path: Path, fields: dict[str, str]) -> str:
    """Genera el contenido del archivo .metadata a partir de los campos extraídos."""
    stem = pdf_path.stem  # e.g. AGN_Marina_v001-1_exp001
    volumen = pdf_path.parent.name  # e.g. v001-1

    fecha_raw = fields.get("Fechas", "")
    fecha_creacion, año_creacion = convert_date(fecha_raw) if fecha_raw else ("", "")

    rango = normalize_rango_fojas(fields.get("Volumen de la unidad de descripción", ""))

    # Estado de conservación se agrega a Notas si existe
    notas = fields.get("Notas", "")
    estado = fields.get("Estado de conservación", "")
    if estado and notas:
        notas = f"{notas} {estado}"
    elif estado:
        notas = estado

    COL = 26  # ancho de la columna de etiqueta (para alineación)

    def row(key: str, val: str) -> str:
        return f"{key:<{COL}}: {val}"

    lines = [
        row("document_name",               stem),
        row("document_path",               ""),
        row("document_status",             "new"),
        row("document_url",                ""),
        row("document_archive",            "Archivo General de la Nación"),
        row("document_Fondo",              fields.get("Fondo", "")),
        row("document_Volumen",            volumen),
        row("document_Caja",               ""),
        row("document_Legajo",             ""),
        row("document_Expediente",         fields.get("Expediente", "")),
        row("document_Nivel_de_Descripcion", fields.get("Nivel de descripción", "")),
        row("document_Fecha_creacion",     fecha_creacion),
        row("document_Año_creacion",       año_creacion),
        row("document_Lugar_creacion",     fields.get("Lugar de expedición", "")),
        row("document_Soporte",            fields.get("Soporte", "")),
        row("document_Descripcion",        fields.get("Alcance y contenido", "")),
        row("document_Rango_fojas",        rango),
        row("document_Num_pags",           ""),
        row("document_Num_pags_escritas",  ""),
        row("document_Notas",              notas),
    ]

    return "\n".join(lines) + "\n"


def main() -> None:
    base = Path(__file__).parent
    pdf_root = base / "metadata/collections/documents/AGN_marina"
    out_dir = base / "metadata/collections/AGN_marina/documentos"
    out_dir.mkdir(parents=True, exist_ok=True)

    pdfs = sorted(pdf_root.rglob("*.pdf"))
    print(f"Procesando {len(pdfs)} PDFs...")

    errors = []
    for pdf_path in pdfs:
        try:
            fields = extract_fields(pdf_path)
            content = build_metadata(pdf_path, fields)
            out_path = out_dir / (pdf_path.stem + ".metadata")
            out_path.write_text(content, encoding="utf-8")
            print(f"  OK  {pdf_path.stem}")
        except Exception as e:
            print(f"  ERR {pdf_path.stem}: {e}")
            errors.append((pdf_path, e))

    print(f"\nListo: {len(pdfs) - len(errors)} generados, {len(errors)} errores.")
    if errors:
        for p, e in errors:
            print(f"  {p.name}: {e}")


if __name__ == "__main__":
    main()