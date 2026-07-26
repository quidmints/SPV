import json, math, time, urllib.request
ser=json.load(open("eth_daily.json"))
px=[p for _,p in ser]; ts=[t for t,_ in ser]
r=[(i, math.log(px[i]/px[i-1])) for i in range(1,len(px))]
worst=min(r,key=lambda x:x[1])
wi=worst[0]
print("worst day idx",wi,"date",time.strftime("%Y-%m-%d",time.gmtime(ts[wi]/1000)),
      "logret",f"{worst[1]:.1%}")
# worst 30-day rolling realized var window
W=30; best=None
for i in range(W,len(r)):
    v=sum(x[1]**2 for x in r[i-W:i])
    if best is None or v>best[1]: best=(i,v)
print("worst 30d window ends",time.strftime("%Y-%m-%d",time.gmtime(ts[best[0]]/1000)),
      "ann.vol",f"{math.sqrt(best[1]/W*365):.0%}")
def k5(sym,start_ms,end_ms,interval="5m"):
    out=[]; cur=start_ms
    while cur<end_ms:
        u=(f"https://api.binance.com/api/v3/klines?symbol={sym}&interval={interval}"
           f"&startTime={cur}&limit=1000")
        k=json.load(urllib.request.urlopen(u,timeout=20))
        if not k: break
        for c in k: out.append((c[0],float(c[4])))
        cur=k[-1][0]+1; 
        if len(k)<1000: break
        time.sleep(0.2)
    return out
# 5m for the worst 30d window (+/- a few days)
end=ts[best[0]]; start=end-40*86400000
fine=k5("ETHUSDT",start,end+5*86400000,"5m")
json.dump(fine,open("eth_5m_stress.json","w"))
print("5m stress candles",len(fine),
      "from",time.strftime("%Y-%m-%d",time.gmtime(fine[0][0]/1000)),
      "to",time.strftime("%Y-%m-%d",time.gmtime(fine[-1][0]/1000)))
# 1m for the worst single day
ds=ts[wi]-86400000; de=ts[wi]+86400000
day1=k5("ETHUSDT",ds,de,"1m")
json.dump(day1,open("eth_1m_crash.json","w"))
print("1m crash candles",len(day1))
