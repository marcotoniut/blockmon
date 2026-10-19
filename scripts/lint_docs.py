"""Checks for doc drift: section cross-references resolve and every label is named."""

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs" / "architecture"

SECTION = re.compile(r"^#{2,3} (\d+(?:\.\d+)?)[.\s]", re.MULTILINE)
REFERENCE = re.compile(r"`?([a-z-]+\.md)`?\s+§§?\s*(\d[\d.,\s-]*\d|\d)")
LABEL = re.compile(r"\bblockmon/[a-z0-9-]+(?:/[a-z0-9-]+)*/v\d+\b")

# Labels that don't name a protocol object, so no doc is needed.
FIXTURES = {
    "blockmon/aa/v0": "archived G0a boundary-shift pair (conformance/gen)",
    "blockmon/aa/v01": "archived G0a boundary-shift pair (conformance/gen)",
    "blockmon/ruleset/v0": "slice B's stand-in ruleset hash",
}


def tracked(*patterns: str) -> list[Path]:
    out = subprocess.run(
        ["git", "ls-files", *patterns], cwd=ROOT, capture_output=True, text=True, check=True
    )
    return [ROOT / line for line in out.stdout.splitlines()]


def numbers(spec: str) -> list[str]:
    found: list[str] = []
    for part in re.split(r"[,\s]+", spec):
        first, sep, last = part.partition("-")
        if sep and first.isdigit() and last.isdigit():
            found.extend(str(n) for n in range(int(first), int(last) + 1))
        elif part:
            found.append(part)
    return found


def unresolved_references(sections: dict[str, set[str]]) -> list[str]:
    problems: list[str] = []
    for path in tracked("*.md", "*.odin", "*.rs", "*.sol", "*.py", "*.sh", "justfile"):
        text = path.read_text(encoding="utf-8")
        for match in REFERENCE.finditer(text):
            doc = match.group(1)
            if doc not in sections:
                continue
            for n in numbers(match.group(2)):
                if n not in sections[doc] and n.split(".")[0] not in sections[doc]:
                    line = text.count("\n", 0, match.start()) + 1
                    problems.append(f"{path.relative_to(ROOT)}:{line}: {doc} has no §{n}")
    return problems


def unnamed_labels(docs_text: str) -> list[str]:
    named = set(LABEL.findall(docs_text))
    problems: list[str] = []
    for path in tracked("*.odin", "*.sol", "*.sh", "*.py"):
        for label in sorted(set(LABEL.findall(path.read_text(encoding="utf-8")))):
            if label not in named and label not in FIXTURES:
                problems.append(f"{path.relative_to(ROOT)}: {label} is named in no doc")
    return problems


def main() -> int:
    docs = sorted(DOCS.glob("*.md"))
    sections = {d.name: set(SECTION.findall(d.read_text(encoding="utf-8"))) for d in docs}
    docs_text = "\n".join(d.read_text(encoding="utf-8") for d in docs)
    problems = unresolved_references(sections) + unnamed_labels(docs_text)
    for p in problems:
        print(p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
