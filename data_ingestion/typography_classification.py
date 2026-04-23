"""
data_ingestion/typography_classification.py
────────────────────────────────────────────
Clasifica el tipo de caligrafía de una imagen manuscrita.

Modos de operación (en orden de preferencia):
  1. Modelo local en MODEL_DIR (directorio con weights + config)
  2. Servidor Gradio (si GRADIO_URL está definida en entorno)

El tipo de caligrafía resultante se guarda en:
  - La operación typography_classified (nota con el tipo)
  - El campo calligraphy_type del documento correspondiente

Uso:
  python typography_classification.py --image-id 42 --model-dir models/typography/
  python typography_classification.py --image-id 42  # usa GRADIO_URL
"""

import argparse
import json
import os
from pathlib import Path

from database.migration.db import get_conn, Operations
from database.crud_operations import Images


# ── Tipos de caligrafía soportados ────────────────────────────────────
VALID_CALLIGRAPHY_TYPES = {
    "humanistica",
    "cortesana",
    "procesal",
    "encadenada",
    "gothic",
    "default",
}


def _classify_with_local_model(image_path: str, model_dir: Path) -> tuple[str, float]:
    """
    Clasifica usando un modelo local (PyTorch / transformers).
    Devuelve (calligraphy_type, confidence).

    Espera encontrar en model_dir:
      - config.json  — con label2id y id2label
      - model.pt o pytorch_model.bin
    """
    import torch
    from PIL import Image as PILImage
    from torchvision import transforms

    config_path = model_dir / "config.json"
    if not config_path.exists():
        raise FileNotFoundError(f"config.json no encontrado en {model_dir}")

    with open(config_path) as f:
        config = json.load(f)

    id2label: dict = config.get("id2label", {})

    # Buscar pesos del modelo
    weights_candidates = [
        model_dir / "model.pt",
        model_dir / "pytorch_model.bin",
    ]
    weights_path = next((p for p in weights_candidates if p.exists()), None)
    if weights_path is None:
        raise FileNotFoundError(f"No se encontraron pesos en {model_dir}")

    # Transformaciones estándar para imágenes de documentos
    transform = transforms.Compose([
        transforms.Resize((224, 224)),
        transforms.Grayscale(num_output_channels=3),
        transforms.ToTensor(),
        transforms.Normalize(mean=[0.485, 0.456, 0.406],
                             std=[0.229, 0.224, 0.225]),
    ])

    img = PILImage.open(image_path).convert("RGB")
    tensor = transform(img).unsqueeze(0)

    model = torch.load(weights_path, map_location="cpu")
    model.eval()

    with torch.no_grad():
        logits = model(tensor)
        probs  = torch.softmax(logits, dim=-1)[0]
        pred   = probs.argmax().item()
        conf   = probs[pred].item()

    calligraphy_type = id2label.get(str(pred), "default")
    return calligraphy_type, conf


def _classify_with_gradio(image_path: str, gradio_url: str) -> tuple[str, float]:
    """
    Clasifica vía servidor Gradio.
    Espera un endpoint que acepte una imagen y devuelva
    {"label": "...", "confidence": float}.
    """
    import requests

    with open(image_path, "rb") as f:
        response = requests.post(
            f"{gradio_url.rstrip('/')}/api/predict",
            files={"data": f},
            timeout=60,
        )
    response.raise_for_status()
    data = response.json()

    # Formato Gradio estándar: {"data": [{"label": "...", "confidences": [...]}]}
    result = data.get("data", [{}])[0]
    label      = result.get("label", "default")
    confidence = 0.0
    for item in result.get("confidences", []):
        if item.get("label") == label:
            confidence = item.get("confidence", 0.0)
            break

    return label, confidence


def classify_typography(
    image_id: int,
    model_dir: Path | None = None,
    collaborator_id: int | None = None,
) -> dict:
    """
    Clasifica la tipografía de una imagen y registra el resultado en BD.

    Devuelve dict con calligraphy_type, confidence y operation_id.
    """
    gradio_url = os.environ.get("GRADIO_URL", "")

    with get_conn() as conn:
        image = Images.get_by_id(conn, image_id)
        if image is None:
            raise ValueError(f"Imagen no encontrada: image_id={image_id}")

        image_path = image["image_filename"]
        if not Path(image_path).exists():
            raise FileNotFoundError(f"Archivo no encontrado: {image_path}")

        print(f"  → Clasificando: {Path(image_path).name}")

        # ── Elegir backend ─────────────────────────────────────────
        if model_dir is not None and model_dir.exists():
            calligraphy_type, confidence = _classify_with_local_model(
                image_path, model_dir
            )
            backend = f"modelo local ({model_dir.name})"
        elif gradio_url:
            calligraphy_type, confidence = _classify_with_gradio(
                image_path, gradio_url
            )
            backend = f"Gradio ({gradio_url})"
        else:
            raise EnvironmentError(
                "Ni --model-dir existe ni GRADIO_URL está definida. "
                "Proporciona al menos uno de los dos."
            )

        # Normalizar a tipos válidos
        if calligraphy_type.lower() not in VALID_CALLIGRAPHY_TYPES:
            calligraphy_type = "default"

        print(f"  ✓ [{backend}] calligraphy_type={calligraphy_type}  "
              f"confidence={confidence:.3f}")

        # ── Actualizar calligraphy_type en el documento ────────────
        cur = conn.cursor()
        cur.execute(
            "UPDATE public.documents "
            "SET calligraphy_type = %s, calligraphy_confidence = %s "
            "WHERE document_id = %s",
            (calligraphy_type, confidence, image["document_id"]),
        )

        # ── Registrar operación typography_classified ──────────────
        op_id = Operations.record_and_link(
            conn,
            operation_type="typography_classified",
            entity="image",
            entity_id=image_id,
            collaborator_id=collaborator_id,
        )

        return {
            "calligraphy_type": calligraphy_type,
            "confidence":       confidence,
            "operation_id":     op_id,
        }


def main():
    parser = argparse.ArgumentParser(
        description="Clasificar tipografía de una imagen manuscrita."
    )
    parser.add_argument("--image-id", type=int, required=True,
                        help="ID de la imagen en BD.")
    parser.add_argument("--model-dir", type=Path, default=None,
                        help="Directorio del modelo local (opcional; fallback: GRADIO_URL).")
    parser.add_argument("--collaborator-id", type=int, default=None)
    args = parser.parse_args()

    print(f"▶ Clasificación tipográfica para image_id={args.image_id}...")
    result = classify_typography(
        image_id=args.image_id,
        model_dir=args.model_dir,
        collaborator_id=args.collaborator_id,
    )

    print()
    print("═" * 50)
    print(f"  calligraphy_type : {result['calligraphy_type']}")
    print(f"  confidence       : {result['confidence']:.3f}")
    print(f"  operation_id     : {result['operation_id']}")
    print("═" * 50)


if __name__ == "__main__":
    main()
