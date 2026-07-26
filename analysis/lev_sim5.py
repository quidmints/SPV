# Round 5: CORRECTED squeeze. lev_sim4 wrongly modeled QU!D's SP BOLD as a private reserve
# that the leverage program alone fills/drains -> "self-funding 1.00x". That is wrong: the SP
# BOLD is drained by THREE exogenous things QU!D does not control, and to ZERO on demand:
#   (1) branch-wide liquidations burn it (BOLD -> ETH),
#   (2) ANY strict-BOLD swap-out: swap(BOLD, WETH, false, ...) -> Aux._withdraw "BOLD via SP",
#   (3) ANY strict-BOLD redeem: redeem(amt, BOLD) -> same path.
# So delever cannot rely on the SP balance. This finds the RING-FENCED reserve actually needed,
# parameterized by `ext` = exogenous drain intensity per stress window (1.0 = adversary empties
# the SP every stress window; the achievable worst case, since (2)/(3) are permissionless).
import json, math, time
ser=json.load(open("eth_daily.json")); px=[p for _,p in ser]
r=[math.log(px[i]/px[i-1]) for i in range(1,len(px))]; N=len(r)
MCR=1.10

def alive(L):
    liq=(1.0/L)/MCR; out=[]; live=True; pk=px[0]
    for i in range(1,len(px)):
        p=px[i]
        if live:
            if p>pk: pk=p
            if p<=pk*(1-liq): live=False
        else:
            if p>=pk: live=True; pk=p
        out.append(1 if live else 0)
    return out

def trace(E,L,ext):
    # program opens in calm (deposit BOLD to SP), delevers in stress (needs BOLD). Each stress
    # window the SP is exogenously drained by `ext`. Returns (peak outstanding debt, required
    # ring-fenced reserve = worst single-window shortfall the drained SP cannot cover).
    Vt=L*E; dpf=(L-1)/L; al=alive(L); Nn=0.0; SP=0.0; prev=1; peakDebt=0.0; reqRes=0.0
    for i in range(N):
        ai=abs(r[i]); op=dv=0.0
        if al[i]==1 and prev==1 and Nn<Vt and ai<0.03: op=min((Vt-Nn)*0.05,Vt-Nn); Nn+=op
        elif Nn>0 and ai>0.05: dv=min(Nn,Nn*ai*2.0); Nn-=dv
        SP+=op*dpf
        if ai>0.03: SP=max(0.0, SP*(1.0-ext))      # exogenous SP drain on stress days
        peakDebt=max(peakDebt, Nn*dpf)
        need=dv*dpf
        if need>0:
            reqRes=max(reqRes, need-SP)            # what the drained SP can't cover this window
            SP=max(0.0, SP-need)
        prev=al[i]
    return peakDebt, reqRes

print("=== CORRECTED squeeze: SP BOLD is exogenously drainable (liquidations + strict-BOLD swaps/redeems) ===")
print("ext=0   -> lev_sim4's WRONG assumption (SP is the program's private reserve)")
print("ext=1.0 -> adversary empties the SP in every stress window (achievable; (2)/(3) are permissionless)\n")
print(f"{'E':>6}{'L':>4} | {'peakDebt':>9} | required ring-fenced reserve (% of backing)")
print(f"{'':>6}{'':>4} | {'E*(L-1)':>9} | {'ext=0':>8}{'ext=0.5':>9}{'ext=1.0':>9}")
for E in [0.05,0.10,0.20]:
    for L in [3,5]:
        pd,_=trace(E,L,0.0)
        rr0=trace(E,L,0.0)[1]; rr5=trace(E,L,0.5)[1]; rr1=trace(E,L,1.0)[1]
        print(f"{E:>6.0%}{L:>4} | {pd:>8.1%} | {rr0:>8.1%}{rr5:>9.1%}{rr1:>9.1%}")

print("\nReading: lev_sim4's 'self-funding' is the ext=0 column (reserve ~0). Under adversarial")
print("SP drain (ext=1.0) the required ring-fenced reserve climbs to ~the peak outstanding")
print("leveraged debt = E*(L-1) of backing, held OUTSIDE the SP. THAT is the real cost of the")
print("program, and the cap must bind on it: dedicated BOLD reserve >= worst-case delever demand.")
