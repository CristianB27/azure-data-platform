"""Genera un CSV sintético de telemetría para la ruta batch.

Uso:
  python scripts/generar_csv.py                  # lote sano (3 % nulos, 2 % duplicados)
  python scripts/generar_csv.py --nulos 0.4      # lote malo, el quality gate debe bloquearlo
"""
import argparse
import csv
import random
from datetime import datetime, timedelta
from pathlib import Path

DEVICES = [f"sensor-{i:02d}" for i in range(1, 6)]
COLUMNS = ["device_id", "event_time", "temperature", "humidity", "pressure"]


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--rows", type=int, default=1000)
    p.add_argument("--nulos", type=float, default=0.03)
    p.add_argument("--duplicados", type=float, default=0.02)
    p.add_argument("--salida", default="data/telemetria_batch.csv")
    a = p.parse_args()

    random.seed(42)
    base = datetime(2026, 9, 28)
    rows = []
    for _ in range(a.rows):
        t = base + timedelta(seconds=random.randint(0, 3 * 24 * 3600 - 1))
        # 10 % de fechas en otro formato, para probar la normalización
        fmt = "%d/%m/%Y %H:%M:%S" if random.random() < 0.10 else "%Y-%m-%d %H:%M:%S"
        rows.append([
            random.choice(DEVICES),
            t.strftime(fmt),
            round(random.gauss(26, 2), 2),
            round(random.gauss(55, 8), 2),
            round(random.gauss(1013, 5), 2),
        ])

    for r in random.sample(rows, int(a.rows * a.nulos)):
        r[random.randint(0, 4)] = ""
    rows += [list(r) for r in random.sample(rows, int(a.rows * a.duplicados))]
    random.shuffle(rows)

    out = Path(a.salida)
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(COLUMNS)
        w.writerows(rows)
    print(f"{len(rows)} filas escritas en {out}")


if __name__ == "__main__":
    main()
