"""Reads judge verdicts (judge-*.jsonl next to judge-set.jsonl) and prints the flag rate.

    python3 -I eval/rewrite/judge-report.py eval/reports/rewrite-v1/layered

A change counts as flagged when at least two of the judges flag it (either kind).
"""
import collections, glob, json, os, sys

d = sys.argv[1]
items = {}
for line in open(os.path.join(d, "judge-set.jsonl")):
    if line.strip():
        o = json.loads(line)
        items[o["item"]] = o
keypath = os.path.join(d, "judge-key.json")
key = json.load(open(keypath)) if os.path.exists(keypath) else {}
judges = sorted(p for p in glob.glob(os.path.join(d, "judge-[0-9]*.jsonl")))
votes = collections.defaultdict(list)
for path in judges:
    seen = 0
    for line in open(path):
        if not line.strip():
            continue
        v = json.loads(line)
        votes[(v["item"], int(v["change"]))].append((v["verdict"], v.get("reason", "")))
        seen += 1
    print(f"{os.path.basename(path)}: {seen} verdicts")
total = sum(len(o["changes"]) for o in items.values())
flagged = []
for (item, k), vs in sorted(votes.items()):
    bad = [v for v in vs if v[0] != "ok"]
    if len(bad) >= 2:
        flagged.append((item, k, bad))
print(f"\nchanges: {total}, flagged by 2+ judges: {len(flagged)} ({100 * len(flagged) / max(total, 1):.1f} %)")
kinds = collections.Counter(collections.Counter(v[0] for v in bad).most_common(1)[0][0] for _, _, bad in flagged)
print("by kind:", dict(kinds))
for item, k, bad in flagged:
    o = items.get(item, {})
    ch = o.get("changes", ["?"] * (k + 1))
    print(f"\n- {item} ({key.get(item, '?')}) #{k}: {ch[k] if k < len(ch) else '?'}  [{', '.join(f'{v}: {r}' for v, r in bad)}]")
    print(f"  before: {o.get('before')}\n  after:  {o.get('after')}")
