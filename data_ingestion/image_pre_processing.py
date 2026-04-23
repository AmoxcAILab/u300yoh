"""
data_ingestion/image_pre_processing.py
───────────────────────────────────────
Preprocesamiento de imágenes: ecualización de histograma CLAHE +
ajuste de contraste. Opera sobre una imagen registrada en BD e inserta
la versión procesada como nueva fila en `images` (image_type='processed').

Registra la operación `image_preprocessed` sobre la imagen original.

Uso:
  python image_pre_processing.py --image-id 42
  python image_pre_processing.py --image-id 42 --clip-limit 2.5 --tile-size 8
"""

import argparse
from pathlib import Path

from PIL import Image, ImageOps, ImageEnhance
import numpy as np

from database.migration.db import get_conn, Operations
from database.crud_operations import Images


# CLAHE aproximado vía PIL + numpy (no requiere OpenCV)
def _apply_clahe(img: Image.Image, clip_limit: float, tile_size: int) -> Image.Image:
    """
    Ecualización de histograma adaptativa por celdas (CLAHE simplificado).
    Trabaja en escala de grises; si la imagen es RGB, convierte y vuelve.
    """
    is_rgb = img.mode == "RGB"
    gray = img.convert("L") if is_rgb else img.copy()

    arr = np.array(gray, dtype=np.uint8)
    h, w = arr.shape
    ts = tile_size

    # Dividir en celdas y ecualizar cada una
    out = np.zeros_like(arr)
    for y in range(0, h, ts):
        for x in range(0, w, ts):
            tile = arr[y : y + ts, x : x + ts]
            eq = _clahe_tile(tile, clip_limit)
            out[y : y + ts, x : x + ts] = eq

    result_gray = Image.fromarray(out, mode="L")

    if is_rgb:
        # Fusionar en canal L de LAB aproximado (re-combinar con canales color)
        r, g, b = img.split()
        # Escalar la luminancia ecualizada a cada canal proporcionalmente
        orig_gray = np.array(gray, dtype=np.float32) + 1
        scale = (np.array(result_gray, dtype=np.float32) + 1) / orig_gray

        def _scale_channel(ch_arr: np.ndarray) -> np.ndarray:
            return np.clip(ch_arr * scale, 0, 255).astype(np.uint8)

        r2 = Image.fromarray(_scale_channel(np.array(r)), "L")
        g2 = Image.fromarray(_scale_channel(np.array(g)), "L")
        b2 = Image.fromarray(_scale_channel(np.array(b)), "L")
        return Image.merge("RGB", (r2, g2, b2))

    return result_gray


def _clahe_tile(tile: np.ndarray, clip_limit: float) -> np.ndarray:
    """Ecualización de histograma con recorte (clip) para un tile."""
    hist, _ = np.histogram(tile.flatten(), bins=256, range=(0, 256))
    total = tile.size

    # Recortar y redistribuir
    clip = int(clip_limit * total / 256)
    excess = np.sum(np.maximum(hist - clip, 0))
    hist = np.minimum(hist, clip)
    hist += excess // 256  # redistribución uniforme del exceso

    # CDF
    cdf = hist.cumsum()
    cdf_min = cdf[cdf > 0][0]
    lut = np.round((cdf - cdf_min) / (total - cdf_min) * 255).astype(np.uint8)
    return lut[tile]


def preprocess_image(
    image_id: int,
    clip_limit: float = 2.0,
    tile_size: int = 8,
    contrast_factor: float = 1.2,
    collaborator_id: int | None = None,
) -> dict:
    """
    Preprocesa una imagen registrada en BD.

    1. Carga la imagen desde `image_filename`
    2. Aplica CLAHE
    3. Aplica ajuste de contraste
    4. Guarda la imagen procesada con sufijo `_processed`
    5. Registra la nueva imagen en `images` (image_type='processed')
    6. Registra la operación `image_preprocessed` sobre la imagen original

    Devuelve dict con processed_image_id y ruta del archivo.
    """
    with get_conn() as conn:
        image = Images.get_by_id(conn, image_id)
        if image is None:
            raise ValueError(f"Imagen no encontrada: image_id={image_id}")

        src_path = Path(image["image_filename"])
        if not src_path.exists():
            raise FileNotFoundError(f"Archivo de imagen no encontrado: {src_path}")

        # ── Cargar y procesar ──────────────────────────────────────
        img = Image.open(src_path)
        img = _apply_clahe(img, clip_limit=clip_limit, tile_size=tile_size)
        img = ImageEnhance.Contrast(img).enhance(contrast_factor)

        # ── Guardar versión procesada ──────────────────────────────
        processed_path = src_path.with_stem(src_path.stem + "_processed")
        img.save(processed_path)

        # ── Registrar imagen procesada en BD ──────────────────────
        processed_id = Images.create(
            conn,
            document_id=image["document_id"],
            image_filename=str(processed_path),
            image_type="processed",
            page_number=image.get("page_number"),
            parent_image_id=image_id,
            collaborator_id=collaborator_id,
        )

        print(f"  ✓ image_id={image_id} → processed_id={processed_id}  [{processed_path}]")
        return {"processed_image_id": processed_id, "processed_path": str(processed_path)}


def main():
    parser = argparse.ArgumentParser(
        description="Preprocesar imagen: CLAHE + ajuste de contraste."
    )
    parser.add_argument("--image-id", type=int, required=True,
                        help="ID de la imagen original en BD.")
    parser.add_argument("--clip-limit", type=float, default=2.0,
                        help="Límite de recorte CLAHE (default: 2.0).")
    parser.add_argument("--tile-size", type=int, default=8,
                        help="Tamaño de tile CLAHE en píxeles (default: 8).")
    parser.add_argument("--contrast-factor", type=float, default=1.2,
                        help="Factor de mejora de contraste (default: 1.2).")
    parser.add_argument("--collaborator-id", type=int, default=None)
    args = parser.parse_args()

    print(f"▶ Preprocesando image_id={args.image_id}...")
    result = preprocess_image(
        image_id=args.image_id,
        clip_limit=args.clip_limit,
        tile_size=args.tile_size,
        contrast_factor=args.contrast_factor,
        collaborator_id=args.collaborator_id,
    )
    print(f"  processed_image_id : {result['processed_image_id']}")
    print(f"  processed_path     : {result['processed_path']}")


if __name__ == "__main__":
    main()
