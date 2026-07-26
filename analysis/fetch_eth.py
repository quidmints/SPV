import urllib.request, json, time
def klines(start_ms):
    url=("https://api.binance.com/api/v3/klines?symbol=ETHUSDT&interval=1d"
         f"&startTime={start_ms}&limit=1000")
    with urllib.request.urlopen(url, timeout=20) as r:
        return json.load(r)
start=int(time.mktime(time.strptime("2017-08-17","%Y-%m-%d")))*1000
rows=[]; cur=start
while True:
    k=klines(cur)
    if not k: break
    for c in k:
        rows.append((c[0], float(c[4])))  # openTime ms, close
    nxt=k[-1][0]+86400000
    if nxt<=cur or len(k)<1000: 
        if len(k)<1000: break
    cur=nxt
    time.sleep(0.25)
# dedup + sort
seen={}; 
for t,c in rows: seen[t]=c
ser=sorted(seen.items())
with open("eth_daily.json","w") as f: json.dump(ser,f)
print("days",len(ser),"from",time.strftime("%Y-%m-%d",time.gmtime(ser[0][0]/1000)),
      "to",time.strftime("%Y-%m-%d",time.gmtime(ser[-1][0]/1000)),
      "first",ser[0][1],"last",ser[-1][1])
