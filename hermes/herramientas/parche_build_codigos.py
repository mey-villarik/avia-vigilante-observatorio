#!/usr/bin/env python3
"""
Parche para web/vigilante/build.py (VPS): que cada fuente use el CÓDIGO de la lista de la web.

Problema: build.py tomaba el «id» que escribía AVIA en cada parte, o lo inventaba a partir del
nombre. El mismo medio acababa como eldeber, eldeb, el_deber… y cada variante era una fuente nueva.

Con el parche, antes de usar un id se busca en fuentes_activas.json (la lista que baja de Supabase):
  1. mismo código  2. misma dirección  3. mismo sitio web  4. mismo nombre
Si no aparece, se deja el id que traía (Supabase la tratará como propuesta de AVIA, en pausa).

Uso (en el VPS):  python3 parche_build_codigos.py /root/.hermes/web/vigilante/build.py
Guarda una copia build.py.bak-AAAAMMDD-HHMM y se puede ejecutar más de una vez.
"""
import re
import shutil
import sys
import time

MARCA = "# --- codigo_canonico (parche AVIA) ---"

FUNCION = MARCA + r'''
_ACTIVAS = None
_AGREGADORES = {"news.google.com", "google.com", "facebook.com", "m.facebook.com", "x.com", "twitter.com",
                "youtube.com", "instagram.com", "t.me", "tiktok.com", "linkedin.com", "gdeltproject.org",
                "api.gdeltproject.org"}


def _fuentes_activas():
    global _ACTIVAS
    if _ACTIVAS is None:
        _ACTIVAS = []
        for p in (os.environ.get("FUENTES_ACTIVAS", ""),
                  "/opt/data/skills/vigilancia-fuentes-bolivia/fuentes_activas.json",
                  "/root/.hermes/skills/vigilancia-fuentes-bolivia/fuentes_activas.json",
                  os.path.expanduser("~/.hermes/skills/vigilancia-fuentes-bolivia/fuentes_activas.json")):
            if p and os.path.exists(p):
                try:
                    with open(p, encoding="utf-8") as fh:
                        _ACTIVAS = json.load(fh).get("fuentes", []) or []
                    break
                except Exception:
                    pass
    return _ACTIVAS


def _url_normal(u):
    u = (u or "").strip().lower()
    u = re.sub(r"^https?://(www\.)?", "", u)
    return u.rstrip("/")


def _dominio(u):
    m = re.match(r"^(?:https?://)?(?:www\.)?([^/:?#]+)", (u or "").strip().lower())
    h = m.group(1) if m else ""
    return _url_normal(u) if (not h or h in _AGREGADORES) else h


def codigo_canonico(f):
    fid = str(f.get("id") or clave(f.get("nombre")) or "fuente").replace(" ", "_")
    activas = _fuentes_activas()
    if not activas:
        return fid
    if any(a.get("codigo") == fid for a in activas):
        return fid
    url = f.get("url") or ""
    if url:
        for a in activas:
            if _url_normal(a.get("url")) == _url_normal(url):
                return a["codigo"]
        dom = _dominio(url)
        for a in activas:
            if _dominio(a.get("url")) == dom:
                return a["codigo"]
    nombre = clave(f.get("nombre"))
    if nombre:
        for a in activas:
            if clave(a.get("nombre")) == nombre:
                return a["codigo"]
    return fid
# --- fin codigo_canonico ---


'''

PATRON_FID = re.compile(r'fid = str\(f\.get\("id"\) or clave\(f\.get\("nombre"\)\) or "fuente"\)\.replace\(" ", "_"\)')


def main():
    ruta = sys.argv[1] if len(sys.argv) > 1 else "/root/.hermes/web/vigilante/build.py"
    txt = open(ruta, encoding="utf-8").read()
    if MARCA in txt:
        print("build.py ya tiene el parche: no se cambia nada.")
        return
    if not PATRON_FID.search(txt):
        sys.exit("No encuentro la línea «fid = str(f.get(\"id\") …» en build.py: no se cambia nada. Pásale este mensaje a Claude.")
    if "\ndef main():" not in txt:
        sys.exit("No encuentro «def main():» en build.py: no se cambia nada.")
    copia = f"{ruta}.bak-{time.strftime('%Y%m%d-%H%M')}"
    shutil.copy2(ruta, copia)
    txt = PATRON_FID.sub("fid = codigo_canonico(f)", txt, count=1)
    txt = txt.replace("\ndef main():", "\n" + FUNCION + "def main():", 1)
    if not re.search(r"^import .*\bre\b", txt, re.M):
        txt = "import re\n" + txt
    open(ruta, "w", encoding="utf-8").write(txt)
    print(f"Listo. Copia de seguridad en {copia}")


if __name__ == "__main__":
    main()
