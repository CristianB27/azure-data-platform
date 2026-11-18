"""Genera los 3 diagramas del Proyecto 09 en SVG (editable) y PNG (2x).

Uso:  python docs/diagramas/generar_diagramas.py
El PNG requiere playwright con Google Chrome instalado.
"""
import html
import os
import re

OUT = os.path.dirname(os.path.abspath(__file__))
FONT = "Segoe UI, Arial, sans-serif"
INK, GRAY, LINE = "#222222", "#6b6b6b", "#555555"
LAYER = {"bronze": ("#f4e4d4", "#a0522d"), "silver": ("#e8ecf0", "#66778a"),
         "gold": ("#f9efc8", "#a68000"), "fail": ("#ffffff", "#c0392b")}


class SVG:
    def __init__(self, name, w, h, title):
        self.name, self.w, self.h, self.el = name, w, h, []
        self.el.append(f'<rect width="{w}" height="{h}" fill="#ffffff"/>')
        self.t(30, 38, title, 20, bold=True)

    def t(self, x, y, s, size=14, bold=False, color=INK, anchor="start"):
        b = ' font-weight="600"' if bold else ""
        self.el.append(f'<text x="{x}" y="{y}" font-family="{FONT}" font-size="{size}"{b} '
                       f'fill="{color}" text-anchor="{anchor}">{html.escape(s)}</text>')

    def box(self, x, y, w, h, title, sub="", kind=None, dashed=False):
        fill, stroke = LAYER.get(kind, ("#ffffff", LINE))
        d = ' stroke-dasharray="6 4"' if dashed else ""
        self.el.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="4" fill="{fill}" '
                       f'stroke="{stroke}" stroke-width="1.3"{d}/>')
        cy = y + h / 2 + (-4 if sub else 5)
        self.t(x + w / 2, cy, title, 15, bold=True, anchor="middle")
        if sub:
            self.t(x + w / 2, cy + 20, sub, 12.5, color=GRAY, anchor="middle")

    def group(self, x, y, w, h, label):
        self.el.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="6" fill="#f7f7f7" '
                       f'stroke="#d0d0d0" stroke-width="1"/>')
        self.t(x + 12, y + 22, label, 13, color=GRAY)

    def diamond(self, cx, cy, w, h, label):
        pts = f"{cx},{cy - h / 2} {cx + w / 2},{cy} {cx},{cy + h / 2} {cx - w / 2},{cy}"
        self.el.append(f'<polygon points="{pts}" fill="#ffffff" stroke="{LINE}" stroke-width="1.3"/>')
        if label:
            self.t(cx, cy + 5, label, 13, bold=True, anchor="middle")

    def arrow(self, pts, label=None, lx=None, ly=None, dashed=False, head=True):
        d = "M" + " L".join(f"{x},{y}" for x, y in pts)
        da = ' stroke-dasharray="5 4"' if dashed else ""
        mk = ' marker-end="url(#a)"' if head else ""
        self.el.append(f'<path d="{d}" fill="none" stroke="{LINE}" stroke-width="1.3"{da}{mk}/>')
        if label:
            self.t(lx, ly, label, 12.5, color=GRAY, anchor="middle")

    def save(self):
        defs = ('<defs><marker id="a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" '
                f'markerHeight="7" orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="{LINE}"/>'
                '</marker></defs>')
        svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{self.w}" height="{self.h}" '
               f'viewBox="0 0 {self.w} {self.h}">{defs}' + "\n".join(self.el) + "</svg>\n")
        path = os.path.join(OUT, self.name + ".svg")
        with open(path, "w", encoding="utf-8") as f:
            f.write(svg)
        return path


def arquitectura():
    s = SVG("D1_arquitectura_final", 1540, 640, "Arquitectura final")
    # streaming
    s.box(40, 100, 170, 64, "Generador", "Python")
    s.box(250, 100, 170, 64, "Event Hubs", "4 particiones", dashed=True)
    s.box(460, 100, 190, 64, "Stream Analytics", "ventana de 1 min", dashed=True)
    s.box(460, 220, 190, 54, "Tabla de alertas", "temp. > 30")
    s.arrow([(210, 132), (250, 132)])
    s.arrow([(420, 132), (460, 132)])
    s.arrow([(555, 164), (555, 220)])
    # batch
    s.box(40, 360, 170, 64, "CSV histórico")
    s.box(250, 360, 400, 64, "Data Factory", "copia CSV → Parquet (diario 2:00 a. m.)")
    s.arrow([(210, 392), (250, 392)])
    # data lake
    s.group(700, 70, 560, 400, "ADLS Gen2 · stp09utbdl461l")
    s.box(725, 210, 130, 110, "Bronze", "crudo", kind="bronze")
    s.diamond(905, 265, 70, 60, "")
    s.t(905, 310, "quality", 12.5, color=GRAY, anchor="middle")
    s.t(905, 326, "gate", 12.5, color=GRAY, anchor="middle")
    s.box(960, 210, 130, 110, "Silver", "limpio", kind="silver")
    s.box(1110, 210, 130, 110, "Gold", "agregado", kind="gold")
    s.arrow([(855, 265), (870, 265)])
    s.arrow([(940, 265), (960, 265)])
    s.arrow([(1090, 265), (1110, 265)])
    s.t(980, 420, "Bronze → Silver → Gold con Data Flows de Data Factory", 12.5, color=GRAY,
        anchor="middle")
    s.t(980, 440, "Silver y Gold en Parquet", 12.5, color=GRAY, anchor="middle")
    s.arrow([(650, 132), (690, 132), (690, 245), (725, 245)])
    s.arrow([(650, 392), (690, 392), (690, 285), (725, 285)])
    # consumo
    s.box(1300, 210, 200, 110, "Synapse", "Serverless SQL · vistas")
    s.arrow([(1240, 265), (1300, 265)])
    # transversal
    s.box(725, 500, 230, 54, "Private Endpoint", "acceso privado al lake", dashed=True)
    s.arrow([(840, 500), (840, 470)], head=False, dashed=True)
    s.box(40, 500, 280, 54, "Terraform + Azure Pipelines", "despliega toda la plataforma")
    s.box(360, 500, 290, 54, "Azure Monitor", "alertas por correo")
    s.t(40, 610, "Línea discontinua: recurso temporal, se crea y destruye con el parámetro "
        "deployExpensive.", 12.5, color=GRAY)
    return s


def quality_gate():
    s = SVG("D2_pipeline_quality_gate", 1340, 390, "Pipeline Bronze → Silver → Gold con quality gate")
    s.t(30, 62, "Mismo flujo en pl_batch_medallion (CSV) y pl_streaming_medallion (JSON de Stream "
        "Analytics).", 13, color=GRAY)
    y, h = 150, 70
    s.box(40, y, 140, h, "Bronze", kind="bronze")
    s.box(220, y, 160, h, "df_calidad", "total, nulos, distintos")
    s.box(420, y, 160, h, "leer_metricas", "Lookup")
    s.diamond(690, y + h / 2, 150, 100, "¿pasa?")
    s.box(810, y, 170, h, "df_silver", "limpia y deduplica", kind="silver")
    s.box(1020, y, 170, h, "df_gold", "agregado diario", kind="gold")
    s.box(610, 300, 160, 60, "Fail", "bloquear_promocion", kind="fail")
    s.arrow([(180, y + 35), (220, y + 35)])
    s.arrow([(380, y + 35), (420, y + 35)])
    s.arrow([(580, y + 35), (615, y + 35)])
    s.arrow([(765, y + 35), (810, y + 35)], "sí", 787, y + 25)
    s.arrow([(980, y + 35), (1020, y + 35)])
    s.arrow([(690, y + 85), (690, 300)], "no", 705, 270)
    s.t(690, y - 20, "total > 0 y nulos ≤ 20 %", 13, color=GRAY, anchor="middle")
    s.t(1230, y + 30, "→ vistas de", 13, color=GRAY)
    s.t(1230, y + 48, "Synapse", 13, color=GRAY)
    return s


def cicd():
    s = SVG("D3_cicd", 1420, 380, "CI/CD de la infraestructura")
    y, h = 110, 64
    s.box(40, y, 140, h, "Rama faseN")
    s.box(220, y, 160, h, "Pull Request", "GitHub")
    s.group(420, 80, 720, 125, "Azure Pipelines")
    s.box(440, y, 170, h, "validate", "fmt · validate")
    s.box(640, y, 170, h, "plan", "terraform plan")
    s.box(840, y, 280, h, "apply", "solo main · aprobación manual")
    s.box(1180, y, 200, h, "Azure", "rg-p09utb-data")
    s.arrow([(180, y + 32), (220, y + 32)])
    s.arrow([(380, y + 32), (440, y + 32)])
    s.arrow([(610, y + 32), (640, y + 32)])
    s.arrow([(810, y + 32), (840, y + 32)])
    s.arrow([(1120, y + 32), (1180, y + 32)])
    s.box(640, 260, 480, 60, "sc-p09utb-azure", "Workload Identity Federation (OIDC), sin contraseñas")
    s.arrow([(880, 260), (880, 205)], dashed=True)
    s.box(1180, 260, 200, 60, "Estado de Terraform", "stp09utbtfstate01")
    s.arrow([(1280, 260), (1280, 174)], dashed=True, head=False)
    s.t(40, 240, "En un PR solo corren validate y plan.", 13, color=GRAY)
    s.t(40, 260, "deployExpensive enciende o apaga", 13, color=GRAY)
    s.t(40, 280, "los recursos costosos.", 13, color=GRAY)
    return s


def render(paths):
    from playwright.sync_api import sync_playwright
    with sync_playwright() as p:
        b = p.chromium.launch(channel="chrome")
        for svg in paths:
            c = open(svg, encoding="utf-8").read()
            w, h = map(int, re.search(r'width="(\d+)" height="(\d+)"', c).groups())
            pg = b.new_page(viewport={"width": w, "height": h}, device_scale_factor=2)
            pg.set_content(f'<html><body style="margin:0">{c}</body></html>')
            pg.screenshot(path=svg[:-4] + ".png")
            pg.close()
        b.close()


if __name__ == "__main__":
    paths = [f().save() for f in (arquitectura, quality_gate, cicd)]
    render(paths)
    print("OK", len(paths))
