import json,sys,re,os
art=sys.argv[1]; name=sys.argv[2]
o=json.load(open(art))
code=o["deployedBytecode"]["object"].removeprefix("0x")
import re as _re
code=_re.sub(r"__\$[0-9a-fA-F]{34}\$__", "0"*40, code)
smap=o["deployedBytecode"]["sourceMap"]
# source id -> path
ids={}
for p,v in o.get("metadata",{}).get("sources",{}).items(): pass
# forge stores id map under 'id' per source in build-info; fall back to ast
# use the compact ast source list if present
srcs=o.get("ast",{}).get("absolutePath")
# decode source map
entries=[];prev=[0,0,0,'-',0]
for e in smap.split(';'):
    f=e.split(':'); cur=list(prev)
    for i,x in enumerate(f):
        if x!='' and i<5: cur[i]=int(x) if i<3 or i==4 else x
    entries.append(cur); prev=cur
# walk bytecode instructions
b=bytes.fromhex(code); i=0; k=0; cost={}
while i<len(b) and k<len(entries):
    op=b[i]; ln=1
    if 0x60<=op<=0x7f: ln=1+(op-0x5f)
    s,l,fid,_,_=entries[k]
    cost[(fid,s,l)]=cost.get((fid,s,l),0)+ln
    i+=ln; k+=1
# aggregate by source offset -> line, only for the target file id
src=open(sys.argv[3]).read()
# build offset->line
nl=[0]
for idx,ch in enumerate(src):
    if ch=='\n': nl.append(idx+1)
import bisect
agg={}
for (fid,s,l),c in cost.items():
    if fid!=int(sys.argv[4]): continue
    line=bisect.bisect_right(nl,s)
    agg[line]=agg.get(line,0)+c
# map lines to enclosing function
# Only functions INSIDE the main contract/library body. Interface declarations above
# it have no code, so billing bytes to them (and to every state declaration that
# follows a small function) is how `totalNetEquityEth` scored 1,204 for a one-line
# interface stub. Anchor at the first `contract`/`library` definition.
anchor=0
m0=re.search(r'^(contract|library|abstract contract)\s', src, re.M)
if m0: anchor=m0.start()
funcs=[]
for m in re.finditer(r'^\s*function\s+([A-Za-z0-9_]+)', src, re.M):
    if m.start()<anchor: continue
    funcs.append((bisect.bisect_right(nl,m.start()), m.group(1)))
funcs.sort()
tot={}
for line,c in agg.items():
    j=bisect.bisect_right(funcs,(line,'\xff'))-1
    fn=funcs[j][1] if j>=0 else '<top-level>'
    tot[fn]=tot.get(fn,0)+c
print(f"{name}: mapped {sum(agg.values()):,} bytes of {len(b):,}")
for fn,c in sorted(tot.items(),key=lambda x:-x[1])[:28]:
    print(f"  {c:>6,}  {fn}")
