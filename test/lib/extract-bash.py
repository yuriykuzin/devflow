#!/usr/bin/env python3
"""Extract the ```bash blocks from cross-tool-runner.md into per-section .sh files.

The point: tests run the REAL bash from the skill spec (not a hand-kept copy), so a
regression in the .md is caught the next time the harness runs. Blocks are grouped by
the nearest preceding section heading:

  ### A.1 -> a1.sh   ### A.2 -> a2.sh   ### A.3 -> a3.sh
  ## Section B -> b.sh   ## Section C -> c.sh   ## Section D -> d.sh

Unmapped headings (e.g. "## Putting it together") reset the slot so their example
blocks are NOT emitted.
"""
import sys, re, os

def slot_for(heading):
    if re.search(r'#+\s*A\.1', heading): return 'a1'
    if re.search(r'#+\s*A\.2', heading): return 'a2'
    if re.search(r'#+\s*A\.3', heading): return 'a3'
    if re.search(r'#+\s*Section B', heading): return 'b'
    if re.search(r'#+\s*Section C', heading): return 'c'
    if re.search(r'#+\s*Section D', heading): return 'd'
    return None

def main():
    md, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    blocks = {}
    cur = None
    inblock = False
    buf = []
    for line in open(md).read().splitlines():
        if inblock:
            if line.strip() == '```':
                inblock = False
                if cur:
                    if cur in blocks:
                        print("ERROR: section '%s' has more than one ```bash block; the extractor "
                              "expects exactly one per mapped section, so a stray illustrative block "
                              "would be sourced as runner code. Move it under an unmapped heading, or "
                              "merge it into the section block." % cur, file=sys.stderr)
                        sys.exit(1)
                    blocks[cur] = ['\n'.join(buf)]
            else:
                buf.append(line)
            continue
        if re.match(r'#{1,6}\s', line):          # a markdown heading
            cur = slot_for(line)                 # None for unmapped headings -> stop assigning
            continue
        if line.strip().startswith('```bash'):
            inblock = True
            buf = []
    for slot, bl in blocks.items():
        with open(os.path.join(outdir, slot + '.sh'), 'w') as f:
            f.write('\n'.join(bl) + '\n')
    print("extracted:", ",".join(sorted(blocks)) or "(none)")
    # Sanity: every slot we depend on must exist.
    missing = [s for s in ('a1','a2','a3','b','c','d') if s not in blocks]
    if missing:
        print("ERROR: missing sections:", ",".join(missing), file=sys.stderr)
        sys.exit(1)

if __name__ == '__main__':
    main()
