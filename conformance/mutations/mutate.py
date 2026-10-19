#!/usr/bin/env python3
"""Mutation harness for the conformance gates. See README.md."""

import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

CATCHERS = {
    "canonical-test": "just canonical-test",
    "kernel-test": "just kernel-test",
    "tree-v1": "just tree-v1 && git diff --quiet --exit-code -- conformance/vectors/",
    "t1-v1": "just t1-v1 && git diff --quiet --exit-code -- conformance/vectors/",
    "bounded-access": 'just bounded-access "1 16 256"',
    "slice-b-test": "just slice-b-test",
    "g0c-v1": "just t1-v1 && just g0c-v1",
}

# A mutation that breaks the build trips every gate, so it would be
# misread as caught.
BUILDS = {
    ".odin": "just lint-odin",
    ".sol": "cd prototype/slice-b/contracts && forge build --silent",
}


@dataclass(frozen=True)
class Mutation:
    id: str
    breaks: str
    path: str
    old: str
    new: str
    caught_by: tuple[str, ...]


CANONICAL = "protocol/canonical/canonical.odin"
TREE = "protocol/canonical/tree.odin"
STORE = "protocol/canonical/store.odin"
KERNEL = "protocol/kernel/kernel.odin"
CONTRACT = "prototype/slice-b/contracts/src/BattleSettlement.sol"

MUTATIONS = [
    Mutation(
        "enc-enum-zero",
        "an enum decodes discriminant 0",
        CANONICAL,
        "\tfor v in valid {\n\t\tif b[0] == v {",
        "\tif b[0] == 0 {\n\t\treturn 0, .None\n\t}\n\tfor v in valid {\n\t\tif b[0] == v {",
        ("canonical-test",),
    ),
    Mutation(
        "enc-enum-uncommitted",
        "an unassigned discriminant cannot be committed",
        CANONICAL,
        "enc_enum :: proc(buf: ^[dynamic]byte, v: u8) {\n\tappend(buf, v)",
        "enc_enum :: proc(buf: ^[dynamic]byte, v: u8) {\n\tassert(v != 0)\n\tappend(buf, v)",
        ("t1-v1",),
    ),
    Mutation(
        "enc-trailing",
        "top-level decode accepts trailing bytes",
        CANONICAL,
        "return .None if r.off == len(r.data) else .Trailing_Bytes",
        "return .None if r.off <= len(r.data) else .Trailing_Bytes",
        ("canonical-test",),
    ),
    Mutation(
        "enc-utf8",
        "a string decodes invalid UTF-8",
        CANONICAL,
        "\tif !utf8.valid_string(s) {",
        "\tif !utf8.valid_string(s) && n > len(r.data) {",
        ("canonical-test",),
    ),
    Mutation(
        "kernel-order",
        "WRONG_SUBJECT is checked before PERMIT_NOT_RESERVED",
        KERNEL,
        "\tif permit.status != PERMIT_RESERVED {\n"
        "\t\treturn reject(w, REJECT_PERMIT_NOT_RESERVED) // single reservation; no reuse\n"
        "\t}\n"
        "\tif permit.subject != cmd.subject {\n"
        "\t\treturn reject(w, REJECT_WRONG_SUBJECT)\n"
        "\t}\n",
        "\tif permit.subject != cmd.subject {\n"
        "\t\treturn reject(w, REJECT_WRONG_SUBJECT)\n"
        "\t}\n"
        "\tif permit.status != PERMIT_RESERVED {\n"
        "\t\treturn reject(w, REJECT_PERMIT_NOT_RESERVED) // single reservation; no reuse\n"
        "\t}\n",
        ("kernel-test",),
    ),
    Mutation(
        "kernel-release-on-failure",
        "a failed roll releases its permit and capability",
        KERNEL,
        "\t\tfx = Effects{outcome = OUTCOME_ROLL_FAILED, roll = roll}",
        "\t\tnext.permits[permit_index].status = PERMIT_RESERVED\n"
        "\t\tnext.supply.consumed -= 1\n"
        "\t\tfx = Effects{outcome = OUTCOME_ROLL_FAILED, roll = roll}",
        ("kernel-test", "t1-v1"),
    ),
    Mutation(
        "kernel-expiry-inclusive",
        "a permit is still live at its expiry position",
        KERNEL,
        "if ctx.position >= permit.expiry_position {",
        "if ctx.position > permit.expiry_position {",
        ("t1-v1",),
    ),
    Mutation(
        "kernel-extant",
        "valid input no longer requires extant == created",
        KERNEL,
        "\tif u64(len(w.blockmon)) != s.created {",
        "\tif u64(len(w.blockmon)) != s.created && s.created > s.envelope {",
        ("t1-v1",),
    ),
    Mutation(
        "kernel-round-wraps",
        "an assigned round past u64 wraps instead of matching no context",
        KERNEL,
        "\tif q >= max(u64) - m.entropy_safety_margin {",
        "\tif q >= max(u64) - m.entropy_safety_margin && m.round_period == 0 {",
        ("kernel-test", "t1-v1"),
    ),
    Mutation(
        "transcript-v0",
        "transcripts under world/v1 hash under the archived v0 domain",
        KERNEL,
        "canonical.protocol_hash(canonical.DOMAIN_TRANSITION_V1, bytes[:])",
        "canonical.protocol_hash(canonical.DOMAIN_TRANSITION, bytes[:])",
        ("t1-v1", "g0c-v1"),
    ),
    Mutation(
        "repeats-kept",
        "an identical repeated entry is committed as a second leaf",
        KERNEL,
        "\t\tif n > 0 && e.key == sorted[n - 1].key &&",
        "\t\tif n < 0 && e.key == sorted[n - 1].key &&",
        ("kernel-test", "t1-v1"),
    ),
    Mutation(
        "kernel-creature-exists",
        "a capture proceeds over a creature that already exists",
        KERNEL,
        "\t\tif b.creature_id == creature {\n\t\t\treturn reject(w, REJECT_CREATURE_EXISTS)",
        "\t\tif b.creature_id == creature && b.owner != b.owner {\n"
        "\t\t\treturn reject(w, REJECT_CREATURE_EXISTS)",
        ("kernel-test", "t1-v1"),
    ),
    Mutation(
        "world-field-order",
        "WorldCommitmentV1 puts the encounter root in the subject field",
        TREE,
        "\tcopy(buf[0:32], s_root[:])\n"
        "\tcopy(buf[32:64], b_root[:])\n"
        "\tcopy(buf[64:96], e_root[:])",
        "\tcopy(buf[0:32], e_root[:])\n"
        "\tcopy(buf[32:64], b_root[:])\n"
        "\tcopy(buf[64:96], s_root[:])",
        ("tree-v1", "t1-v1"),
    ),
    Mutation(
        "update-unanchored",
        "a bounded update no longer checks the claimed pre-state root",
        TREE,
        "\tif tree_climb(key, old_leaf, siblings) != claimed_old_root {\n"
        "\t\treturn {}, .Old_Root_Mismatch\n"
        "\t}\n",
        "",
        ("canonical-test", "kernel-test"),
    ),
    Mutation(
        "store-write-unpublished",
        "a store write leaves the domain root where it was",
        STORE,
        "\tset_store_root(s, tag, sub)\n\treturn sub\n}",
        "\t_ = sub\n\treturn store_root(s, tag)\n}",
        ("canonical-test", "kernel-test", "bounded-access"),
    ),
    Mutation(
        "store-population-cost",
        "classifying a subtree reads every singleton",
        STORE,
        "\tif entry, found := s.singletons[commitment]; found {",
        "\tfor _ in s.singletons {\n\t\ts.node_reads += 1\n\t}\n"
        "\tif entry, found := s.singletons[commitment]; found {",
        ("bounded-access",),
    ),
    Mutation(
        "kernel-full-derivation",
        "the kernel's advance derives a world root from the full world",
        KERNEL,
        "\tdisplaced: [dynamic]Displaced\n\tdefer delete(displaced)\n",
        "\tdisplaced: [dynamic]Displaced\n\tdefer delete(displaced)\n\t_ = world_root(after)\n",
        ("bounded-access",),
    ),
    Mutation(
        "kernel-half-advanced",
        "a failed later key leaves earlier writes in the store",
        KERNEL,
        "\t#reverse for d in displaced {\n"
        "\t\tcanonical.store_write(&t.store, d.key.tag, d.key.key, d.leaf, d.present)\n"
        "\t}\n",
        "\t_ = t\n\t_ = displaced\n",
        ("kernel-test",),
    ),
    Mutation(
        "settle-unsigned-commitment",
        "a timeout with no checkpoint records the caller's commitment",
        CONTRACT,
        "            stateCommitment = bytes32(0);\n",
        "",
        ("slice-b-test",),
    ),
    Mutation(
        "settle-shared-key",
        "a participant may anchor the counterparty's key",
        CONTRACT,
        "        require(!peer.registered || (peer.edPk != edPk && peer.xPk != xPk), "
        '"key anchored by the counterparty");\n',
        "",
        ("slice-b-test",),
    ),
    Mutation(
        "settle-unbound-keys",
        "the checkpoint digest omits the anchored channel keys",
        CONTRACT,
        "                    edPkA,\n                    edPkB,\n",
        "                    bytes32(0),\n                    bytes32(0),\n",
        ("slice-b-test",),
    ),
]


def run(cmd: str, cwd: Path) -> bool:
    done = subprocess.run(
        ["bash", "-c", cmd], cwd=cwd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
    return done.returncode == 0


def reset(tree: Path) -> None:
    subprocess.run(["git", "checkout", "--quiet", "--", "."], cwd=tree, check=True)


def main(argv: list[str]) -> int:
    for tool in ("just", "odin", "forge", "git"):
        if shutil.which(tool) is None:
            print(f"{tool} not on PATH: run inside the dev shell (nix develop -c just mutations)")
            return 2
    chosen = [m for m in MUTATIONS if not argv or m.id in argv]
    unknown = set(argv) - {m.id for m in MUTATIONS}
    if unknown:
        print(f"unknown mutation ids: {', '.join(sorted(unknown))}")
        return 2
    catchers = sorted({c for m in chosen for c in m.caught_by})
    builds = sorted({Path(m.path).suffix for m in chosen})

    tree = Path(tempfile.mkdtemp(prefix="blockmon-mutations-"))
    subprocess.run(
        ["git", "worktree", "add", "--quiet", "--detach", str(tree), "HEAD"], cwd=REPO, check=True
    )
    failures = 0
    try:
        checks = [(f"build{b}", BUILDS[b]) for b in builds] + [(c, CATCHERS[c]) for c in catchers]
        for label, cmd in checks:
            green = run(cmd, tree)
            reset(tree)
            print(f"baseline  {label:<15} {'green' if green else 'RED'}")
            if not green:
                failures += 1
        if failures:
            print("a gate that is already red catches every mutation; nothing below would count")
            return 1

        for m in chosen:
            target = tree / m.path
            text = target.read_text()
            if text.count(m.old) != 1:
                print(f"STALE     {m.id:<27} target text no longer occurs exactly once")
                failures += 1
                continue
            target.write_text(text.replace(m.old, m.new))
            if not run(BUILDS[target.suffix], tree):
                reset(tree)
                print(f"UNBUILT   {m.id:<27} the mutated source does not build, so no gate counts")
                failures += 1
                continue
            missed = []
            for c in m.caught_by:
                if run(CATCHERS[c], tree):
                    missed.append(c)
                reset(tree)
                target.write_text(text.replace(m.old, m.new))
            reset(tree)
            if missed:
                print(f"SURVIVED  {m.id:<27} {m.breaks}; green: {', '.join(missed)}")
                failures += 1
            else:
                print(f"caught    {m.id:<27} {m.breaks}; red: {', '.join(m.caught_by)}")
    finally:
        subprocess.run(["git", "worktree", "remove", "--force", str(tree)], cwd=REPO, check=False)

    print(f"{len(chosen)} mutations, {failures} uncaught, stale or unbuilt")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
