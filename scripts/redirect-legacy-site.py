from pathlib import Path
import sys,json
base=Path(sys.argv[1]);slug=sys.argv[2]
for f in base.rglob('*.html'):
    rel=f.relative_to(base).as_posix()
    suffix=rel.removesuffix('index.html')
    target='https://atomsprout.com/'+slug+'/'+suffix
    f.write_text('<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Moved to AtomSprout</title><meta name="robots" content="noindex"><link rel="canonical" href="'+target+'"><meta http-equiv="refresh" content="0;url='+target+'"></head><body><a href="'+target+'">Continue to AtomSprout</a><script>location.replace('+json.dumps(target)+'+location.search+location.hash)</script></body></html>')
