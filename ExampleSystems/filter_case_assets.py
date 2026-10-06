"""
filter_case_assets.py
---------------------
Create a copy of a Macro case folder with a list of assets removed.

Everything in the source case is copied unchanged, except the asset JSON files
(the folders/files listed under "assets" in system_data.json), from which every
asset instance whose id matches the exclusion list is removed. The removed ids
are recorded in <dest>/excluded_assets.txt.

Time series CSVs (e.g. vre_availability_*.csv) are copied as-is: columns for
removed assets are simply unused.

Usage (from ExampleSystems/):
    python filter_case_assets.py wecc_20p_11z wecc_20p_11z_egsfiltered \
        --exclude-file egs_assets_to_exclude.txt

Options:
    --exclude-file FILE   one entry per line (# comments allowed); repeatable
    --exclude ID ...      entries given on the command line
    --exact               match whole ids only (default: id contains the entry)
    --overwrite           replace <dest> if it already exists

Uses the 'modeling' conda environment.
"""

import argparse
import json
import re
import shutil
import sys
from pathlib import Path


def read_exclusions(files, entries):
    out = list(entries or [])
    for f in files or []:
        for line in Path(f).read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                out.append(line)
    return list(dict.fromkeys(out))  # de-duplicate, keep order


def output_dir_ignore(src: Path):
    """Skip results folders written by previous runs (OutputDir, OutputDir_001, ...)."""
    settings = src / "settings" / "macro_settings.json"
    out_dir = None
    if settings.exists():
        out_dir = json.loads(settings.read_text()).get("OutputDir")

    def ignore(dirpath, names):
        skip = {n for n in names if n == ".DS_Store"}
        if out_dir and Path(dirpath) == src:
            skip |= {n for n in names if re.fullmatch(re.escape(out_dir) + r"(_\d+)?", n)}
        return skip

    return ignore


def asset_json_files(case: Path):
    """All asset JSON files referenced by system_data.json (dirs are searched recursively)."""
    system_data = json.loads((case / "system_data.json").read_text())
    periods = system_data["case"] if "case" in system_data else [system_data]
    files = set()
    for period in periods:
        path = case / period["assets"]["path"]
        if path.is_dir():
            files |= set(path.rglob("*.json"))
        elif path.suffix == ".json":
            files.add(path)
    return sorted(files)


def filter_file(path: Path, is_excluded):
    """Remove matching instances from one asset JSON file; return removed ids."""
    data = json.loads(path.read_text())
    removed = []
    for group in list(data):
        inst = data[group].get("instance_data")
        if isinstance(inst, dict):  # single-instance group
            if is_excluded(inst["id"]):
                removed.append(inst["id"])
                del data[group]
        elif isinstance(inst, list):
            keep = [i for i in inst if not is_excluded(i["id"])]
            removed += [i["id"] for i in inst if is_excluded(i["id"])]
            if keep:
                data[group]["instance_data"] = keep
            else:
                del data[group]  # an empty instance list would not load
    if removed:
        if data:
            # indent=4 reproduces the input formatting byte for byte
            path.write_text(json.dumps(data, indent=4))
        else:
            path.unlink()  # every asset in the file was excluded
    return removed


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("src", type=Path, help="source case folder")
    p.add_argument("dest", type=Path, help="new case folder to create")
    p.add_argument("--exclude-file", action="append", help="file with one entry per line")
    p.add_argument("--exclude", nargs="+", help="entries given on the command line")
    p.add_argument("--exact", action="store_true", help="match whole ids only")
    p.add_argument("--overwrite", action="store_true", help="replace dest if it exists")
    args = p.parse_args()

    src, dest = args.src.resolve(), args.dest.resolve()
    patterns = read_exclusions(args.exclude_file, args.exclude)
    if not patterns:
        sys.exit("No exclusions given (use --exclude-file and/or --exclude).")
    if not (src / "system_data.json").exists():
        sys.exit(f"{src} is not a case folder (no system_data.json).")
    if dest == src or src in dest.parents:
        sys.exit("dest must be outside src.")
    if dest.exists():
        if not args.overwrite:
            sys.exit(f"{dest} already exists (use --overwrite to replace it).")
        shutil.rmtree(dest)

    if args.exact:
        exact = set(patterns)
        is_excluded = lambda i: i in exact
    else:
        is_excluded = lambda i: any(s in i for s in patterns)

    shutil.copytree(src, dest, symlinks=True, ignore=output_dir_ignore(src))

    removed_by_file = {}
    for f in asset_json_files(dest):
        removed = filter_file(f, is_excluded)
        if removed:
            removed_by_file[f.relative_to(dest)] = removed

    # Report
    all_removed = [i for ids in removed_by_file.values() for i in ids]
    unique_removed = sorted(set(all_removed))
    unused = [s for s in patterns if not any((i == s) if args.exact else (s in i) for i in unique_removed)]
    print(f"Created {dest}")
    print(f"Removed {len(all_removed)} asset instances ({len(unique_removed)} unique ids) "
          f"from {len(removed_by_file)} files:")
    for f, ids in removed_by_file.items():
        print(f"  {f}: {len(ids)}")
    if unused:
        print(f"WARNING: {len(unused)} entries matched no asset: {unused}")

    (dest / "excluded_assets.txt").write_text(
        f"# Assets removed from {src.name} by filter_case_assets.py "
        f"({'exact' if args.exact else 'substring'} match)\n" + "\n".join(unique_removed) + "\n")


if __name__ == "__main__":
    main()
