"""Summarises eval/reports/style-*/results.csv: first-word match per tag, AI-voice raw, snippet copying, latency.
Usage: python3 -I eval/style/analyze.py"""
import csv, glob, os, statistics

def pct(v, p):
    v = sorted(v)
    if not v:
        return float('nan')
    return v[min(len(v) - 1, int(round(p * (len(v) - 1))))]

for d in sorted(glob.glob('eval/reports/style-*')):
    f = d + '/results.csv'
    if not os.path.exists(f):
        continue
    rows = list(csv.DictReader(open(f)))
    cold = [r for r in rows if r['pass'] == 'cold']
    out = [os.path.basename(d)]
    for tag in ('style', 'neutral', None):
        if tag is None and 'orig' not in d:
            continue
        sel = [r for r in cold if r['has_expect'] == 'true' and (tag is None or tag in r['tags'].split('|'))]
        if not sel:
            continue
        m = sum(r['match_final'] == 'true' for r in sel)
        mr = sum(r['match_raw'] == 'true' for r in sel)
        out.append(f"{tag or 'all'}: final {m}/{len(sel)} raw {mr}/{len(sel)}")
    out.append("aiRaw %d/%d" % (sum(r['ai_raw'] == 'true' for r in cold), len(cold)))
    out.append("copy %d" % sum(r['style_copy'] == 'true' for r in cold))
    out.append("avg inj %.2f" % statistics.mean(int(r['style_snippets']) for r in cold))
    for name, ps in (('cold', cold), ('replay', [r for r in rows if r['pass'] == 'replay'])):
        fv = [float(r['first_visible_ms']) for r in ps if r['first_visible_ms']]
        tt = [float(r['total_ms']) for r in ps if r['total_ms']]
        sy = [float(r['prompt_sync_ms']) for r in ps if r['prompt_sync_ms']]
        tk = [float(r['decoded_prompt_tokens']) for r in ps if r['decoded_prompt_tokens']]
        out.append(f"{name}: FV {pct(fv,.5):.0f}/{pct(fv,.95):.0f} total {pct(tt,.5):.0f}/{pct(tt,.95):.0f} "
                   f"sync {pct(sy,.5):.0f}/{pct(sy,.95):.0f} tok p50 {pct(tk,.5):.0f}")
    print(' | '.join(out))
