# pip install fpdf2
"""Generate a PDF documenting Oracle-to-PostgreSQL data type and construct mappings.

Reads dashboard/migration_state.json and produces docs/data_type_mapping.pdf.
Run from the repo root:  python scripts/generate_mapping_pdf.py
"""

import json
import os
import sys

from fpdf import FPDF


def _resolve_paths():
    """Return (json_path, output_path) resolved from script location or cwd."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.dirname(script_dir)

    json_path = os.path.join(repo_root, "dashboard", "migration_state.json")
    if not os.path.exists(json_path):
        json_path = os.path.join(os.getcwd(), "dashboard", "migration_state.json")
        repo_root = os.getcwd()

    if not os.path.exists(json_path):
        print(f"ERROR: Cannot find dashboard/migration_state.json", file=sys.stderr)
        sys.exit(1)

    output_dir = os.path.join(repo_root, "docs")
    os.makedirs(output_dir, exist_ok=True)
    return json_path, os.path.join(output_dir, "data_type_mapping.pdf")


def _draw_table_header(pdf, columns, widths):
    """Render a styled table header row."""
    pdf.set_font("Helvetica", "B", 10)
    pdf.set_fill_color(30, 58, 95)
    pdf.set_text_color(255, 255, 255)
    for text, w in zip(columns, widths):
        pdf.cell(w, 8, text, border=1, fill=True)
    pdf.ln()
    pdf.set_font("Helvetica", "", 9)
    pdf.set_text_color(0, 0, 0)


def _draw_simple_row(pdf, cells, widths, fill=False):
    """Render a single-line table row."""
    if fill:
        pdf.set_fill_color(240, 245, 250)
    for text, w in zip(cells, widths):
        pdf.cell(w, 7, text, border=1, fill=fill)
    pdf.ln()


def _estimate_row_height(pdf, cells, widths, line_h):
    """Estimate the height a wrapped row will need (in mm)."""
    max_lines = 1
    for text, w in zip(cells, widths):
        usable = w - 2  # cell padding
        if usable <= 0:
            usable = w
        text_w = pdf.get_string_width(text)
        lines = max(1, int(text_w / usable) + 1)
        if lines > max_lines:
            max_lines = lines
    return max_lines * line_h


def _draw_wrapped_row(pdf, cells, widths, line_h=6, fill=False):
    """Render a row where text may wrap across multiple lines.

    Inserts a page break before the row if it would not fit on the
    current page, preventing split-row rendering artefacts.
    """
    est_h = _estimate_row_height(pdf, cells, widths, line_h)
    page_bottom = pdf.h - pdf.b_margin
    if pdf.get_y() + est_h > page_bottom:
        pdf.add_page()

    x0 = pdf.l_margin
    y0 = pdf.get_y()
    max_y = y0

    if fill:
        pdf.set_fill_color(240, 245, 250)

    for text, w in zip(cells, widths):
        pdf.set_xy(x0, y0)
        pdf.multi_cell(w, line_h, text, border=0, fill=fill)
        if pdf.get_y() > max_y:
            max_y = pdf.get_y()
        x0 += w

    row_h = max_y - y0
    x = pdf.l_margin
    for w in widths:
        pdf.rect(x, y0, w, row_h)
        x += w

    pdf.set_xy(pdf.l_margin, max_y)


def main():
    json_path, output_path = _resolve_paths()

    with open(json_path, "r") as f:
        state = json.load(f)

    data_types = state["data_type_mapping"]
    constructs = state["construct_mapping"]

    artifacts = []
    for pkg in state.get("packages", []):
        artifacts.append({
            "id": pkg["id"],
            "type": "Package",
            "features": pkg.get("oracle_features", []),
        })
    for view in state.get("views", []):
        artifacts.append({
            "id": view["id"],
            "type": "View",
            "features": view.get("oracle_features", []),
        })
    for mv in state.get("materialized_views", []):
        artifacts.append({
            "id": mv["id"],
            "type": "Mat. View",
            "features": mv.get("oracle_features", []),
        })

    pdf = FPDF()
    pdf.set_auto_page_break(auto=True, margin=15)

    # --- Title page ---
    pdf.add_page()
    pdf.set_font("Helvetica", "B", 28)
    pdf.ln(50)
    pdf.cell(0, 16, "Oracle to PostgreSQL", new_x="LMARGIN", new_y="NEXT", align="C")
    pdf.set_font("Helvetica", "B", 22)
    pdf.cell(0, 14, "Data Type & Construct Mapping", new_x="LMARGIN", new_y="NEXT", align="C")
    pdf.ln(20)
    pdf.set_font("Helvetica", "", 14)
    pdf.cell(0, 10, "Automotive Manufacturing Migration", new_x="LMARGIN", new_y="NEXT", align="C")
    pdf.ln(10)
    pdf.set_font("Helvetica", "I", 10)
    pdf.cell(
        0, 8,
        "Generated from dashboard/migration_state.json",
        new_x="LMARGIN", new_y="NEXT", align="C",
    )

    # --- Data Type Mapping table ---
    pdf.add_page()
    pdf.set_font("Helvetica", "B", 16)
    pdf.cell(0, 12, "Data Type Mappings", new_x="LMARGIN", new_y="NEXT")
    pdf.ln(4)

    dt_widths = [55, 55, 80]
    _draw_table_header(pdf, ["Oracle Type", "PostgreSQL Type", "Notes"], dt_widths)

    for i, dt in enumerate(data_types):
        _draw_simple_row(
            pdf,
            [dt["oracle"], dt["postgresql"], dt.get("notes", "")],
            dt_widths,
            fill=(i % 2 == 0),
        )

    # --- Construct Mapping table ---
    pdf.ln(10)
    pdf.set_font("Helvetica", "B", 16)
    pdf.cell(0, 12, "Construct Mappings", new_x="LMARGIN", new_y="NEXT")
    pdf.ln(4)

    cm_widths = [55, 75, 60]
    _draw_table_header(
        pdf, ["Oracle Construct", "PostgreSQL Equivalent", "Notes"], cm_widths,
    )

    pdf.set_font("Helvetica", "", 8)
    for i, cm in enumerate(constructs):
        _draw_wrapped_row(
            pdf,
            [cm["oracle"], cm["postgresql"], cm.get("notes", "")],
            cm_widths,
            fill=(i % 2 == 0),
        )

    # --- Artifact Oracle Feature Usage table ---
    pdf.add_page()
    pdf.set_font("Helvetica", "B", 16)
    pdf.cell(0, 12, "Artifact Oracle Feature Usage", new_x="LMARGIN", new_y="NEXT")
    pdf.ln(4)

    art_widths = [55, 30, 105]
    _draw_table_header(pdf, ["Artifact ID", "Type", "Oracle Features"], art_widths)

    pdf.set_font("Helvetica", "", 8)
    for i, art in enumerate(artifacts):
        features_str = ", ".join(art["features"])
        _draw_wrapped_row(
            pdf,
            [art["id"], art["type"], features_str],
            art_widths,
            fill=(i % 2 == 0),
        )

    pdf.output(output_path)
    print(f"PDF generated: {output_path}")


if __name__ == "__main__":
    main()
