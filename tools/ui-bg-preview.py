#!/usr/bin/env python3
"""Create a self-contained base64 HTML preview for UI background images."""
import argparse, base64, html
from pathlib import Path

p=argparse.ArgumentParser()
p.add_argument('--source', type=Path, default=Path('assets/ui/bg'))
p.add_argument('--output', type=Path, default=Path('assets/ui/bg/ui-bg-preview.html'))
args=p.parse_args()
files=sorted(f for f in args.source.iterdir() if f.suffix.lower() in {'.png','.jpg','.jpeg','.webp'})
cards=[]
for f in files:
    mime={'.jpg':'image/jpeg','.jpeg':'image/jpeg','.webp':'image/webp'}.get(f.suffix.lower(),'image/png')
    data=base64.b64encode(f.read_bytes()).decode('ascii')
    cards.append(f'<figure><img loading="lazy" src="data:{mime};base64,{data}"><figcaption>{html.escape(f.name)}</figcaption></figure>')
args.output.write_text('''<!doctype html><meta charset="utf-8"><title>UI background texture preview</title>
<style>body{background:#171717;color:#eee;font:14px system-ui;margin:2rem}main{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:1rem}figure{margin:0;background:#292929;padding:.5rem;border-radius:.4rem}img{display:block;width:100%}figcaption{padding:.5rem 0 .1rem;overflow-wrap:anywhere}</style>
<h1>UI background textures</h1><main>'''+''.join(cards)+'''</main>\n''',encoding='utf-8')
print(f'Wrote {len(files)} embedded images to {args.output}')
