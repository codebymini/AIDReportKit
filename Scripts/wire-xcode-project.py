#!/usr/bin/env python3
"""Minimal, text-preserving pbxproj edit: add a local Swift package, link products to one
target, and optionally add a source file to that target in the group containing a sibling file."""
import argparse
import hashlib
import re
import sys


def gen_id(seed, text, taken):
    h = hashlib.md5(seed.encode()).hexdigest().upper()[:24]
    while h in text or h in taken:
        h = hashlib.md5((seed + h).encode()).hexdigest().upper()[:24]
    taken.add(h)
    return h


def block_span(text, start_match_end):
    end = text.index("\n\t\t};", start_match_end)
    return start_match_end, end


def insert_in_list(text, span, key, entry):
    start, end = span
    block = text[start:end]
    m = re.search(r"\n\t\t\t" + re.escape(key) + r" = \(\n", block)
    if m:
        close = block.index("\n\t\t\t);", m.end() - 1)
        new_block = block[:close] + "\n\t\t\t\t" + entry + "," + block[close:]
    else:
        nm = re.search(r"\n\t\t\tname = [^\n]*;", block)
        if not nm:
            sys.exit(f"cannot place {key}")
        insertion = f"\n\t\t\t{key} = (\n\t\t\t\t{entry},\n\t\t\t);"
        new_block = block[: nm.end()] + insertion + block[nm.end():]
    return text[:start] + new_block + text[end:], len(new_block) - len(block)


def insert_before(text, marker, lines):
    idx = text.index(marker)
    return text[:idx] + "".join(lines) + text[idx:]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("project")
    ap.add_argument("--target", required=True)
    ap.add_argument("--package-path", required=True)
    ap.add_argument("--products", required=True)
    ap.add_argument("--source")
    ap.add_argument("--group-sibling")
    a = ap.parse_args()

    path = a.project + "/project.pbxproj"
    text = open(path).read()
    if "AIDReportKit" in text:
        sys.exit("AIDReportKit already referenced; refusing to edit twice")
    taken = set()
    products = a.products.split(",")
    pkg_comment = f'XCLocalSwiftPackageReference "{a.package_path}"'
    pkg = gen_id("pkg" + a.package_path + a.target, text, taken)

    # Target and its phases
    tm = re.search(r"^\t\t([0-9A-F]{24}) /\* " + re.escape(a.target) + r" \*/ = \{\n\t\t\tisa = PBXNativeTarget;", text, re.M)
    if not tm:
        sys.exit(f"target {a.target} not found")
    tspan = block_span(text, tm.end())
    tblock = text[tspan[0]:tspan[1]]
    frameworks_phase = re.search(r"([0-9A-F]{24}) /\* Frameworks \*/", tblock).group(1)
    sources_phase = re.search(r"([0-9A-F]{24}) /\* Sources \*/", tblock).group(1)

    build_files, deps = [], []
    for product in products:
        dep = gen_id("dep" + product + a.target, text, taken)
        bf = gen_id("bf" + product + a.target, text, taken)
        deps.append((dep, product))
        build_files.append((bf, dep, product))

    # Sections
    text = insert_before(text, "/* End PBXBuildFile section */", [
        f"\t\t{bf} /* {p} in Frameworks */ = {{isa = PBXBuildFile; productRef = {dep} /* {p} */; }};\n" for bf, dep, p in build_files
    ])
    local_entry = (f"\t\t{pkg} /* {pkg_comment} */ = {{\n\t\t\tisa = XCLocalSwiftPackageReference;\n"
                   f"\t\t\trelativePath = {a.package_path};\n\t\t}};\n")
    if "/* End XCLocalSwiftPackageReference section */" in text:
        text = insert_before(text, "/* End XCLocalSwiftPackageReference section */", [local_entry])
    else:
        marker = "/* Begin XCRemoteSwiftPackageReference section */"
        if marker not in text:
            marker = "/* Begin XCSwiftPackageProductDependency section */"
        text = insert_before(text, marker, [
            "/* Begin XCLocalSwiftPackageReference section */\n", local_entry,
            "/* End XCLocalSwiftPackageReference section */\n\n",
        ])
    text = insert_before(text, "/* End XCSwiftPackageProductDependency section */", [
        f"\t\t{dep} /* {p} */ = {{\n\t\t\tisa = XCSwiftPackageProductDependency;\n"
        f"\t\t\tpackage = {pkg} /* {pkg_comment} */;\n\t\t\tproductName = {p};\n\t\t}};\n" for dep, p in deps
    ])

    def span_of(obj_id):
        m = re.search(r"^\t\t" + obj_id + r" /\*[^\n]*\*/ = \{\n", text, re.M)
        return block_span(text, m.end())

    # Target lists
    tm = re.search(r"^\t\t[0-9A-F]{24} /\* " + re.escape(a.target) + r" \*/ = \{\n\t\t\tisa = PBXNativeTarget;", text, re.M)
    for dep, p in deps:
        text, _ = insert_in_list(text, block_span(text, tm.end()), "packageProductDependencies", f"{dep} /* {p} */")
    for bf, _, p in build_files:
        text, _ = insert_in_list(text, span_of(frameworks_phase), "files", f"{bf} /* {p} in Frameworks */")

    # Project packageReferences
    pm = re.search(r"^\t\t[0-9A-F]{24} /\* Project object \*/ = \{\n", text, re.M)
    text, _ = insert_in_list(text, block_span(text, pm.end()), "packageReferences", f"{pkg} /* {pkg_comment} */")

    # Optional source file
    if a.source:
        name = a.source
        fr = gen_id("fr" + name, text, taken)
        sbf = gen_id("sbf" + name, text, taken)
        text = insert_before(text, "/* End PBXFileReference section */", [
            f'\t\t{fr} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};\n'
        ])
        text = insert_before(text, "/* End PBXBuildFile section */", [
            f"\t\t{sbf} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {fr} /* {name} */; }};\n"
        ])
        group_id = None
        for gm in re.finditer(r"^\t\t([0-9A-F]{24}) /\*[^\n]*\*/ = \{\n\t\t\tisa = PBXGroup;", text, re.M):
            gspan = block_span(text, gm.end())
            if f"/* {a.group_sibling} */," in text[gspan[0]:gspan[1]]:
                group_id = gm.group(1)
                break
        if not group_id:
            sys.exit(f"group containing {a.group_sibling} not found")
        text, _ = insert_in_list(text, span_of(group_id), "children", f"{fr} /* {name} */")
        text, _ = insert_in_list(text, span_of(sources_phase), "files", f"{sbf} /* {name} in Sources */")
        print(f"source group: {group_id}")

    open(path, "w").write(text)
    print(f"package {pkg}; products {', '.join(p for _, p in deps)} -> {a.target}")


main()
