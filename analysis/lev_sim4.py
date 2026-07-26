# Round 4 (holistic): the full leveraged-ETH-LP circuit over real ETH history.
# Tracks, per day: leveraged notional, QU!D's deliverable BOLD in the Stability Pool,
# the surplus (channel C), and the BACKING P&L (interest + penalties + SOR spread
# - amplified LVR - gap-down SP loss - squeeze premium). Answers:
#   (1) SQUEEZE: how much deliverable BOLD must QU!D hold so a crash-delever can't brick unwinds?
#   (2) ACCRETION: is leverage net-positive to QD backing, and where does the tail bite?
#   (3) SOLVENCY: does the amplified LVR break the surplus (reuses sim1-3)?
# Model knobs are stated; directions are robust, exact thresholds +/- a few points.
import json, math, time, statistics
ser=json.load(open("eth_daily.json")); px=[p for _,p in ser]; ts=[t for t,_ in ser]
r=[math.log(px[i]/px[i-1]) for i in range(1,len(px))]; N=len(r)
def yr(i): return int(time.gmtime(ts[i+1]/1000).tm_year)
YEARS=sorted(set(yr(i) for i in range(N)))
K=0.71; BAND=0.02; THETA=0.33; Y=0.06; F=0.02; S0=0.03
MCR=1.10; RATE=0.07; PEN=0.05; SP_INT=0.75; SPREAD=0.0010   # 75% interest->SP; 10bps SOR spread

def run(E,L,SP_init,cap=None,ext_day=0.05,prem_bps=200):
    # E=leveraged equity (frac of backing), L=leverage, SP_init=deliverable BOLD buffer held,
    # cap=hard cap on leveraged notional, ext_day=BOLD sourceable/day in stress, prem_bps=its premium.
    Vt=L*E if cap is None else min(L*E,cap); dpf=(L-1)/L
    Nn=0.0; pk=px[0]; SP=SP_init; cum=0.0
    S=S0; minS=S0; minSP=SP_init; req=0.0; sqz=0.0; brick=0
    worstcover=9.9   # min over days of SP-available / synchronized-run demand (all Nn delevers)
    P={y:{'int':0.0,'pen':0.0,'spr':0.0,'cN':0.0,'gap':0.0,'sqz':0.0} for y in YEARS}
    ddliq=(1.0/L)/MCR
    for i in range(N):
        ri=r[i]; ai=abs(ri); p=px[i+1]; y=yr(i)
        if p>pk: pk=p
        dd=1-p/pk; op=dv=lq=0.0
        if   Nn>0 and dd>ddliq:                 lq=Nn; Nn=0.0; pk=p        # liquidation cascade
        elif Nn>0 and ai>0.05:                  dv=min(Nn,Nn*ai*2.0); Nn-=dv  # voluntary delever
        elif Nn<Vt and ai<0.03 and dd<0.05:     op=min((Vt-Nn)*0.05,Vt-Nn); Nn+=op  # open in calm
        inflow=op*dpf; outflow=dv*dpf+lq*dpf
        SP+=inflow
        need=dv*dpf                              # BOLD QU!D must deliver to delevering LPs
        if need>0:
            take=min(SP,need); SP-=take; short=need-take
            if short>1e-12:
                src=min(ext_day,short); P[y]['sqz']-=src*prem_bps/1e4; sqz+=src*prem_bps/1e4
                if short-src>1e-9: brick+=1
        if lq>0:                                 # SP burns BOLD, banks penalty (or eats gap)
            # loss only if the price GAPS past the MCR buffer in the liquidation day itself
            # (single-day move `ai` beyond the ~9% headroom), NOT the cumulative drawdown.
            SP-=min(SP,lq*dpf); buf=1-1/MCR; gap=max(0.0,ai-buf); pen=max(0.0,PEN-gap)
            P[y]['pen']+=pen*lq*dpf
            if gap>0: P[y]['gap']-=gap*lq*dpf
        P[y]['int']+=Nn*dpf*RATE*SP_INT/365      # 75% borrower interest -> QU!D's SP
        P[y]['spr']+=(op+dv+lq)*SPREAD           # SOR spread on leverage turnover
        amp=Nn*dpf; th=THETA+amp                 # amplified in-range = debt-funded slice
        P[y]['cN']+=F*amp/365 - K*amp*min(ri*ri,BAND*BAND)
        d=Y/365+F*th/365-K*th*min(ri*ri,BAND*BAND); S+=d; minS=min(minS,S)
        cum+=inflow-outflow; req=max(req,-cum); minSP=min(minSP,SP)
        synch=Nn*dpf                              # if EVERYONE delevers this instant
        if synch>1e-9: worstcover=min(worstcover, SP/synch)
    netby={y:sum(P[y].values()) for y in YEARS}
    return dict(minS=minS,minSP=minSP,req=req,sqz=sqz,brick=brick,worstcover=worstcover,
                net=sum(netby.values()),netby=netby,P=P)

print(f"days={N}  (K={K}, theta={THETA}, borrow={RATE:.0%}, penalty={PEN:.0%}, 75%->SP, spread={SPREAD*1e4:.0f}bps)")

print("\n=== (1) SQUEEZE: is the program BOLD-self-funding? (opens pre-fund closes) ===")
print("  req=extra buffer beyond standing SP needed; worstcover=SP/demand if EVERYONE delevers at once")
print(f"{'E':>6}{'L':>4} | {'req buffer':>11}{'synch-run cover':>16}{'  bricks':>8}")
for E in [0.05,0.10,0.20]:
    for L in [2,3,5]:
        x=run(E,L,SP_init=0.0)   # SP_init 0: standing slice is JUST the program's own opens
        cov="inf" if x['worstcover']>9 else f"{x['worstcover']:.2f}x"
        print(f"{E:>6.0%}{L:>4} | {x['req']:>10.1%}{cov:>16}{x['brick']:>8}")

print("\n=== buffer requirement WITH SP_init held + a hard notional cap ===")
print(f"{'E':>6}{'L':>4}{'cap':>6}{'SP_init':>9} | {'minSP':>8}{'sqz$':>8}{'bricks':>8}")
for E in [0.10,0.20]:
    for L in [5]:
        for cap in [0.25,0.50]:
            for spi in [0.10,0.25]:
                x=run(E,L,SP_init=spi,cap=cap)
                print(f"{E:>6.0%}{L:>4}{cap:>6.0%}{spi:>9.0%} | {x['minSP']:>8.1%}{x['sqz']*100:>7.2f}%{x['brick']:>8}")

print("\n=== (2) ACCRETION: net backing P&L of the leverage program, 11y + worst year ===")
print(f"{'E':>6}{'L':>4} | {'11y net':>9}{'worst-yr':>13} | int  pen  spr  cN  gap  sqz  (11y, % backing)")
for E in [0.05,0.10,0.20]:
    for L in [3,5]:
        x=run(E,L,SP_init=0.25,cap=0.50)
        wy=min(x['netby'].items(),key=lambda kv:kv[1])
        agg={k:sum(x['P'][y][k] for y in YEARS) for k in ['int','pen','spr','cN','gap','sqz']}
        comp=" ".join(f"{agg[k]*100:+.1f}" for k in ['int','pen','spr','cN','gap','sqz'])
        print(f"{E:>6.0%}{L:>4} | {x['net']*100:>8.1f}%{(str(wy[0])+':'+format(wy[1]*100,'+.1f')+'%'):>13} | {comp}")

print("\n=== (3) SOLVENCY: surplus minS under the program (with cap=50%, SP_init=25%) ===")
for E in [0.10,0.20]:
    for L in [3,5]:
        x=run(E,L,SP_init=0.25,cap=0.50)
        print(f"  E={E:.0%} L={L}: surplus minS={x['minS']:.1%}  {'INSOLVENT' if x['minS']<0 else 'ok'}")
