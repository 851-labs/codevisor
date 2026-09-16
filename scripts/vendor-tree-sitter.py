#!/usr/bin/env python3
"""Refresh the C-only Tree-sitter sources pinned in the highlighter manifest.

No parser generation or network access is needed when building the apps.
"""
import io
import hashlib
import json
import pathlib
import shutil
import tarfile
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
BASE = ROOT / "packages/swift/CodeHighlighter"


def refresh(entry):
    url = entry.get("archive") or f"https://codeload.github.com/{entry['repository']}/tar.gz/{entry['revision']}"
    with urllib.request.urlopen(url) as response:
        data = response.read()
    if "sha256" in entry and hashlib.sha256(data).hexdigest() != entry["sha256"]:
        raise ValueError(f"Archive checksum mismatch: {entry['name']}")
    archive = tarfile.open(fileobj=io.BytesIO(data), mode="r:gz")
    dest = BASE / "Vendor" / entry["name"]
    if dest.exists():
        shutil.rmtree(dest)
    for member in archive.getmembers():
        parts = pathlib.PurePosixPath(member.name).parts[1:]
        if not parts or not member.isfile() or ".." in parts:
            continue
        relative = pathlib.PurePosixPath(*parts)
        if not any(str(relative).startswith(prefix) for prefix in entry["paths"]):
            continue
        if relative.suffix in {".json", ".rej"}:
            continue
        output = dest / relative
        output.parent.mkdir(parents=True, exist_ok=True)
        with archive.extractfile(member) as source, output.open("wb") as target:
            shutil.copyfileobj(source, target)
    query_roots = [(entry["name"], dest / "queries")]
    if entry["name"] == "markdown":
        query_roots = [("markdown", dest / "tree-sitter-markdown/queries"),
                       ("markdown_inline", dest / "tree-sitter-markdown-inline/queries")]
    for name, source in query_roots:
        if source.exists():
            output = BASE / "Resources/Queries" / name
            if output.exists():
                shutil.rmtree(output)
            output.mkdir(parents=True)
            for query in source.glob("*.scm"):
                if query.name.startswith("highlights") or query.name in {"locals.scm", "injections.scm"}:
                    shutil.copy2(query, output / query.name)
    print(f"Vendored {entry['name']} at {entry['revision']}", flush=True)


if __name__ == "__main__":
    dependencies = json.loads((BASE / "Vendor/manifest.json").read_text())
    for dependency in dependencies:
        refresh(dependency)
    notices = []
    for dependency in dependencies:
        folder = BASE / "Vendor" / dependency["name"]
        licenses = [p for p in folder.iterdir() if p.name.startswith(("LICENSE", "COPYING"))]
        if not licenses:
            raise ValueError(f"Missing license: {dependency['name']}")
        notices.append(f"{dependency['repository']} @ {dependency['revision']}\n")
        notices.extend(p.read_text() for p in sorted(licenses))
    (BASE / "Resources/ThirdPartyNotices.txt").write_text("\n\n".join(notices) + "\n")
