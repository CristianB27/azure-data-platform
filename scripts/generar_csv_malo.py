"""Genera una copia del CSV con 40% de nulos para probar el quality gate.

Crea dos carpetas, cada una con un archivo llamado telemetria.csv
(el nombre que espera el dataset de Data Factory):
  data/malo/telemetria.csv   -> 40% de nulos en cada columna
  data/bueno/telemetria.csv  -> copia fiel del original (para restaurar)
"""
import csv
import os
import random
import shutil

random.seed(42)
ORIGEN = "data/telemetria_batch.csv"
PORCENTAJE = 0.40

with open(ORIGEN, newline="", encoding="utf-8-sig") as f:
    filas = [r for r in csv.reader(f) if r]

encabezado, datos = filas[0], filas[1:]
n = len(datos)
k = round(n * PORCENTAJE)

for col in range(len(encabezado)):
    for i in random.sample(range(n), k):
        datos[i][col] = ""

os.makedirs("data/malo", exist_ok=True)
os.makedirs("data/bueno", exist_ok=True)

with open("data/malo/telemetria.csv", "w", newline="", encoding="utf-8") as f:
    w = csv.writer(f, lineterminator="\n")
    w.writerow(encabezado)
    w.writerows(datos)

shutil.copyfile(ORIGEN, "data/bueno/telemetria.csv")

print(f"Filas: {n} | columnas: {len(encabezado)} | nulos por columna: {k} ({PORCENTAJE:.0%})")
print("Listo: data/malo/telemetria.csv y data/bueno/telemetria.csv")