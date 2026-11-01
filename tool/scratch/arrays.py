#!/usr/bin/env python3
"""Classify the array shapes of the in-scope namespaces."""
import glob
import os
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict

CORE = "http://www.gtk.org/introspection/core/1.0"
CN = "http://www.gtk.org/introspection/c/1.0"
Q = "{" + CORE + "}"

IN_SCOPE = {
    "GLib-2.0.gir", "GObject-2.0.gir", "Gio-2.0.gir", "GdkPixbuf-2.0.gir",
    "cairo-1.0.gir", "Pango-1.0.gir", "Gdk-4.0.gir", "Graphene-1.0.gir",
    "Gsk-4.0.gir", "Gtk-4.0.gir", "Adw-1.gir", "GtkSource-5.gir",
    "GIRepository-3.0.gir",
}

STR_CTYPES = {
    "gchar**", "const gchar* const*", "const gchar**", "char**",
    "const char* const*", "const char**",
}
STR_ELEMS = {"utf8", "filename"}


def cns(el):
    for k, v in el.attrib.items():
        if k.startswith("{" + CN + "}"):
            return v
    return None


def array_of(p):
    a = p.find(Q + "array")
    if a is None:
        return None
    elem = a.find(Q + "type")
    return dict(
        length=a.get("length"),
        zt=a.get("zero-terminated"),
        ctype=cns(a),
        elem_name=elem.get("name") if elem is not None else None,
        elem_ctype=cns(elem) if elem is not None else None,
    )


rows = []
for path in sorted(glob.glob("/usr/share/gir-1.0/*.gir")):
    nsname = os.path.basename(path)
    if nsname not in IN_SCOPE:
        continue
    root = ET.parse(path).getroot()
    for ns_el in root:
        if ns_el.tag != Q + "namespace":
            continue
        for owner_el in ns_el:
            otag = owner_el.tag.split("}")[-1]
            if otag not in ("class", "interface", "record", "union", "callback"):
                continue
            owner_name = owner_el.get("name")
            members = [owner_el] if otag == "callback" else list(owner_el)
            for m in members:
                mtag = m.tag.split("}")[-1]
                if mtag not in ("method", "function", "constructor", "callback", "signal"):
                    continue
                owner = f"{owner_name}.{m.get('name')}"
                psel = m.find(Q + "parameters")
                ps = [p for p in psel if p.tag == Q + "parameter"] if psel is not None else []
                names = [p.get("name") for p in ps]
                for idx, p in enumerate(ps):
                    arr = array_of(p)
                    if arr is None:
                        continue
                    arr.update(ns=nsname, owner=owner, slot=p.get("name"), idx=idx,
                               direction=p.get("direction", "in"),
                               transfer=p.get("transfer-ownership", "none"),
                               caller=p.get("caller-allocates", "1"),
                               names=names)
                    rows.append(arr)
                rv = m.find(Q + "return-value")
                if rv is not None:
                    arr = array_of(rv)
                    if arr is not None:
                        arr.update(ns=nsname, owner=owner, slot="<return>", idx=None,
                                   direction="out",
                                   transfer=rv.get("transfer-ownership", "none"),
                                   caller=rv.get("caller-allocates", "1"),
                                   names=names)
                        rows.append(arr)


def bound_name(r):
    if r["length"] in (None, "0"):
        return None
    i = int(r["length"])
    if i < len(r["names"]):
        return f"{r['names'][i]}@{i}"
    return f"<OOR {i}>"


def is_string_arr(r):
    if r["ctype"] in STR_CTYPES and r["elem_name"] in STR_ELEMS:
        return True
    if r["elem_name"] in STR_ELEMS and r["ctype"] in STR_CTYPES:
        return True
    return False


groups = defaultdict(list)
for r in rows:
    if is_string_arr(r):
        groups["string-array"].append(r)
    elif r["elem_name"] in STR_ELEMS and r["ctype"] in ("gchar*", "const gchar*", "char*", "const char*"):
        groups["counted-string"].append(r)
    elif r["elem_name"] in ("guint8", "guchar", "gchar"):
        groups["bytes"].append(r)
    elif r["elem_name"] in ("gint", "guint", "gboolean", "gdouble", "gfloat", "GType"):
        groups["primitive"].append(r)
    else:
        groups["other"].append(r)

for name in ("string-array", "counted-string", "primitive", "other", "bytes"):
    print(f"===== {name} ({len(groups[name])}) =====")
    for r in sorted(groups[name], key=lambda r: (r["ns"], r["owner"], str(r["slot"]))):
        b = bound_name(r)
        print(f"  {r['ns']:20} {r['owner']:48} {str(r['slot']):20} ctype={str(r['ctype']):22} "
              f"elem={str(r['elem_name']):22} zt={str(r['zt']):4} dir={r['direction']:6} "
              f"len={str(r['length']):4}->{str(b):22} xfer={r['transfer']:5} caller={r['caller']}")
    print()
