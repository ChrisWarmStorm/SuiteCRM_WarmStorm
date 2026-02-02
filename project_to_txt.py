#!/usr/bin/env python3
from __future__ import annotations   # ← must be here (first statement)

import argparse, os, sys, time, io
from pathlib import Path
from typing import Optional

DEFAULT_EXCLUDED_DIRS = {
    ".git", ".hg", ".svn", ".idea", ".vscode", ".venv",
    "__pycache__", "node_modules", "dist", "build", ".cache",
    ".mypy_cache", ".pytest_cache", ".next", ".turbo", ".parcel-cache"
}
DEFAULT_EXCLUDED_EXTS = {
    # archives & binaries 
    ".zip", ".gz", ".bz2", ".xz", ".7z", ".rar", ".tar",
    ".exe", ".dll", ".so", ".dylib", ".bin", ".dat", ".lock",
    # media
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".svg",
    ".mp4", ".mov", ".avi", ".mkv", ".mp3", ".wav", ".flac",
    # docs likely huge or non-text
    ".pdf", ".psd", ".ai"
}
DEFAULT_EXCLUDED_FILES = {
    # huge / noisy lock or cache files (still text, but not helpful)
    "package-lock.json", "pnpm-lock.yaml", "yarn.lock",
    "poetry.lock", "pipfile.lock", ".DS_Store", "Thumbs.db", "project_context.txt"
}

LANG_BY_EXT = {
    ".py": "python", ".js": "javascript", ".ts": "typescript",
    ".tsx": "tsx", ".jsx": "jsx", ".json": "json", ".yml": "yaml",
    ".yaml": "yaml", ".md": "markdown", ".toml": "toml",
    ".ini": "", ".cfg": "", ".conf": "", ".txt": "",
    ".html": "html", ".css": "css", ".scss": "scss", ".sass": "sass",
    ".sh": "bash", ".ps1": "powershell", ".sql": "sql", ".xml": "xml",
    ".java": "java", ".c": "c", ".h": "c", ".cpp": "cpp", ".hpp": "cpp",
    ".rs": "rust", ".go": "go", ".rb": "ruby", ".php": "php",
    ".ipynb": "json"
}

def looks_binary(sample: bytes) -> bool:
    if b"\x00" in sample:
        return True
    # Heuristic: if >30% bytes are non-text-ish, treat as binary
    text_bytes = b"\t\n\r\f\b" + bytes(range(32, 127))
    if not sample:
        return False
    nontext = sum(ch not in text_bytes for ch in sample)
    return (nontext / len(sample)) > 0.30


def read_text_file(path: Path, max_bytes: int) -> Optional[str]:  # 👈 change here
    try:
        with path.open("rb") as f:
            sample = f.read(min(max_bytes, 4096))
            if looks_binary(sample):
                return None
        with path.open("rb") as f:
            data = f.read(max_bytes)
        text = data.decode("utf-8", errors="replace")
        return text.replace("\r\n", "\n").replace("\r", "\n")
    except Exception:
        return None


def is_hidden(p: Path) -> bool:
    # Treat names starting with '.' as hidden (works cross-platform)
    return any(part.startswith(".") and part not in {".", ".."} for part in p.parts)

def should_skip_file(p: Path, args, rel: Path) -> bool:
    name = p.name
    if not args.include_dotfiles and (name.startswith(".") or is_hidden(rel)):
        return True
    if name in args.exclude_files or name in DEFAULT_EXCLUDED_FILES:
        return True
    ext = p.suffix.lower()
    if ext in DEFAULT_EXCLUDED_EXTS or ext in args.exclude_exts:
        return True
    if args.include_exts and ext not in args.include_exts:
        return True
    try:
        size = p.stat().st_size
        if size > args.max_size_mb * 1024 * 1024:
            return True
    except Exception:
        return True
    return False

def should_skip_dir(dirpath: Path, args, rel: Path) -> bool:
    name = dirpath.name
    if not args.include_dotfiles and (name.startswith(".") or is_hidden(rel)):
        return True
    if name in DEFAULT_EXCLUDED_DIRS or name in args.exclude_dirs:
        return True
    return False

def main():
    ap = argparse.ArgumentParser(
        description="Concatenate a project’s text source into one TXT for agent context."
    )
    ap.add_argument("root", help="Project root directory.")
    ap.add_argument("-o", "--output", default="project_context.txt",
                    help="Output TXT path (default: project_context.txt)")
    ap.add_argument("--max-size-mb", type=int, default=2,
                    help="Skip files larger than this many MB (default: 2)")
    ap.add_argument("--include-dotfiles", action="store_true",
                    help="Include dotfiles and hidden paths (default: skip)")
    ap.add_argument("--include-exts", default="", help="Comma-separated whitelist of extensions (e.g., .py,.md)")
    ap.add_argument("--exclude-exts", default="", help="Comma-separated extra excluded extensions (e.g., .log,.csv)")
    ap.add_argument("--exclude-dirs", default="",
                    help="Comma-separated extra excluded dir names (exact match)")
    ap.add_argument("--exclude-files", default="",
                    help="Comma-separated extra excluded file names (exact match)")
    ap.add_argument("--no-fences", action="store_true",
                    help="Do not wrap contents in Markdown code fences.")
    args = ap.parse_args()

    root = Path(args.root).resolve()
    if not root.exists() or not root.is_dir():
        print(f"Error: {root} is not a directory.", file=sys.stderr)
        sys.exit(1)

    # Parse lists
    args.include_exts = {e.strip().lower() for e in args.include_exts.split(",") if e.strip()} if args.include_exts else set()
    args.exclude_exts = {e.strip().lower() for e in args.exclude_exts.split(",") if e.strip()} if args.exclude_exts else set()
    args.exclude_dirs = {d.strip() for d in args.exclude_dirs.split(",") if d.strip()} if args.exclude_dirs else set()
    args.exclude_files = {f.strip() for f in args.exclude_files.split(",") if f.strip()} if args.exclude_files else set()

    included_files = []
    skipped = {"dir": 0, "hidden": 0, "size": 0, "binary": 0, "ext": 0, "other": 0}

    out_path = Path(args.output).resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)

    with io.open(out_path, "w", encoding="utf-8", newline="\n") as out:
        # Header / manifest preface
        ts = time.strftime("%Y-%m-%d %H:%M:%S")
        out.write(f"# PROJECT CONTEXT DUMP\n")
        out.write(f"# Root: {root}\n# Generated: {ts}\n")
        out.write("# Notes: Hidden paths and common junk/binaries are skipped. Sizes > max-size are skipped.\n")
        out.write("#\n# Included files will follow with clear section headers.\n\n")

        # Walk
        for dirpath, dirnames, filenames in os.walk(root):
            dirpath = Path(dirpath)
            rel_dir = dirpath.relative_to(root)

            # Filter directories in-place (os.walk respects modifications)
            keep_dirs = []
            for d in dirnames:
                dpath = dirpath / d
                if should_skip_dir(dpath, args, rel_dir / d):
                    skipped["dir"] += 1
                    continue
                keep_dirs.append(d)
            dirnames[:] = keep_dirs

            # Files
            for fn in filenames:
                fpath = dirpath / fn
                rel = fpath.relative_to(root)
                if fpath.resolve() == out_path:
                    skipped["other"] += 1
                    continue
                if should_skip_file(fpath, args, rel):
                    # heuristic reason counting
                    name = fpath.name
                    if not args.include_dotfiles and (name.startswith(".") or is_hidden(rel)):
                        skipped["hidden"] += 1
                    elif fpath.suffix.lower() in DEFAULT_EXCLUDED_EXTS or fpath.suffix.lower() in args.exclude_exts:
                        skipped["ext"] += 1
                    else:
                        try:
                            if fpath.stat().st_size > args.max_size_mb * 1024 * 1024:
                                skipped["size"] += 1
                            else:
                                skipped["other"] += 1
                        except Exception:
                            skipped["other"] += 1
                    continue

                # Read and binary check
                with fpath.open("rb") as fb:
                    sample = fb.read(4096)
                if looks_binary(sample):
                    skipped["binary"] += 1
                    continue

                text = read_text_file(fpath, max_bytes=args.max_size_mb * 1024 * 1024)
                if text is None:
                    skipped["other"] += 1
                    continue

                included_files.append(str(rel))

                # Write section
                lang = LANG_BY_EXT.get(fpath.suffix.lower(), "")
                out.write("\n\n" + "=" * 80 + "\n")
                out.write(f"=== FILE: {rel} ===\n")
                out.write("=" * 80 + "\n\n")
                if args.no_fences:
                    out.write(text)
                else:
                    fence = lang if lang is not None else ""
                    out.write(f"```{fence}\n{text}\n```\n")

        # Manifest footer
        out.write("\n\n" + "#" * 80 + "\n")
        out.write("# MANIFEST\n")
        out.write("# Included files:\n")
        for p in included_files:
            out.write(f"#  - {p}\n")
        out.write("#\n# Skips summary:\n")
        for k, v in skipped.items():
            out.write(f"#  {k}: {v}\n")
        out.write("# END\n")

    print(f"Done. Wrote: {out_path}")
    print(f"Included files: {len(included_files)} | Skips: {skipped}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
