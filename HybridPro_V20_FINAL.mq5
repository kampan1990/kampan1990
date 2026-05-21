//+------------------------------------------------------------------+
//| HybridPro_V20_FINAL.mq5                                         |
//| M1=BUY grid (bidirectional) | M2=ADX/Trigger | M3=SELL grid     |
//+------------------------------------------------------------------+
#property copyright "HybridPro"
#property version   "20.00"
#property strict
#include <Trade\Trade.mqh>

#define EA_VER     "20.00"
#define EXPIRY_STR "2026.12.31 23:59"
#define MAGIC_1    1111
#define MAGIC_2    2222
#define MAGIC_3    3333
#define PFX        "HP_"

// ── Panel layout ─────────────────────────────────────────────────────
#define PW_OUT   316
#define PW_IN    310
#define HDR_H     30
#define TRIG_H    30
#define MSEC_H    46
#define M2R_H     26
#define STAT_H    52

// ── Color palette ────────────────────────────────────────────────────
#define CB_BORDER  C'42,55,95'
#define CB_BG      C'10,12,20'
#define CB_HDR     C'16,22,46'
#define CB_HDR_LN  C'48,92,210'
#define CB_M1      C'10,15,30'
#define CB_M2      C'13,10,26'
#define CB_M3      C'20,12,5'
#define CB_STAT    C'12,15,26'
#define CB_SEP     C'20,26,48'
#define CB_SEP_HI  C'35,46,80'
#define CB_BAR_BG  C'30,40,65'
#define CA_M1      C'38,128,255'
#define CA_M2      C'162,78,222'
#define CA_M3      C'232,122,12'
#define CL_GOLD    C'255,200,50'
#define CL_POS     C'48,212,98'
#define CL_NEG     C'232,62,62'
#define CL_NEU     C'125,138,162'
#define CL_INFO    C'105,120,150'
#define CL_BRIGHT  C'180,200,228'
#define CL_CYAN    C'0,198,218'
#define CL_WHITE   C'220,228,240'
#define CL_TIME    C'80,95,125'

// ── Font sizes ───────────────────────────────────────────────────────
#define FH  10
#define FN   9
#define FS   8
#define FXS  7

//+------------------------------------------------------------------+
//| Structs                                                          |
//+------------------------------------------------------------------+
struct TriggerState {
   bool   active;
   int    stoppedMagic;
   double trigPrice;
};

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== Enable ==="
input bool   En1          = true;
input bool   En2          = true;
input bool   En3          = true;

input group "=== Lot ==="
input double Lot1         = 0.01;
input double Lot2         = 0.01;
input double Lot3         = 0.01;
input double LotMult1     = 1.0;
input double LotMult2     = 1.0;
input double LotMult3     = 1.0;

input group "=== Grid Spacing (points) ==="
input int    GS1          = 100;
input int    GS2          = 100;
input int    GS3          = 100;

input group "=== Grid Limits ==="
input int    MaxGrid1     = 20;
input int    MaxGrid2     = 10;
input int    MaxGrid3     = 20;

input group "=== Loss Trigger ==="
input double LossTrig1    = 200.0;
input double LossTrig3    = 200.0;
input int    TrigCoolSec  = 300;

input group "=== ADX ==="
input bool            UseADX  = true;
input ENUM_TIMEFRAMES ADXTF   = PERIOD_H1;
input int             ADXPer  = 14;
input double          ADXMin  = 20.0;

input group "=== Take Profit ==="
input bool   UseSepTP     = true;
input double TP1          = 5.0;   // SepTP target M1 (USD)
input double TP2          = 5.0;   // SepTP target M2 (USD)
input double TP3          = 5.0;   // SepTP target M3 (USD)
input bool   UsePairTP    = true;
input double TPPair       = 10.0;  // PairTP target — any 2-magic combo (USD)
input bool   UseTotTP     = true;
input double TPTot        = 15.0;  // TotTP target — all 3 magics combined (USD)
// AbsorbN: max losers closed per TP event (0 = absorb as many as GP allows)
// Realized net is always >= TP target regardless of this setting.
input int    AbsorbN      = 0;
input int    SKCount      = 1;     // survivors kept open with BE SL per magic
input int    SKBEPts      = 5;     // BE SL offset (points) for survivors

input group "=== BPK Breakeven ==="
input bool   UseBPK       = false;
input double BPKMinProfit = 50.0;
input int    BPKBEPts     = 10;

input group "=== Runner (Best Positions Keeper) ==="
input int    RunKeepN1    = 5;
input int    RunKeepN3    = 5;
input int    RunBEPts     = 10;
input double TPRun1       = 50.0;
input double TPRun3       = 50.0;
input bool   UseTPAll     = true;
input double TPAll        = 20.0;

input group "=== Spread ==="
input int    MaxSpread    = 50;

input group "=== Panel ==="
input bool   ShowPanel    = true;
input int    PanelX       = 10;
input int    PanelY       = 20;

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade T1, T2, T3;
int      hADX         = INVALID_HANDLE;
int      gADXDir      = 0;
datetime gTrigCoolEnd = 0;

TriggerState gTrig;

double gLastBuy  = 0.0;
double gLastSell = 0.0;

ulong  gRunTk1[];
ulong  gRunTk3[];

double   gDailyLot1  = 0.0;
double   gDailyLot2  = 0.0;
double   gDailyLot3  = 0.0;
datetime gTodayStart = 0;

double gBalanceHigh = 0.0;

//+------------------------------------------------------------------+
//| HELPERS                                                          |
//+------------------------------------------------------------------+
double NLot(double v) {
   double s  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   v = MathFloor(v / s) * s;
   if(v < mn) v = mn;
   if(v > mx) v = mx;
   return NormalizeDouble(v, 2);
}

CTrade* TR(int m) {
   if(m == MAGIC_1) return &T1;
   if(m == MAGIC_2) return &T2;
   return &T3;
}

bool SpreadOK() {
   return (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= MaxSpread;
}

int Count(int m) {
   int c = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != m) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      c++;
   }
   return c;
}

// Full PNL including runners (trigger checks, dashboard)
double PNL(int m) {
   double p = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != m) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      p += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return p;
}

void SortPairsByPnl(ulong &tk[], double &pf[], int c, bool ascending) {
   for(int i = 0; i < c - 1; i++)
      for(int j = i + 1; j < c; j++) {
         bool sw = ascending ? (pf[j] < pf[i]) : (pf[j] > pf[i]);
         if(sw) {
            ulong  tu = tk[i]; tk[i] = tk[j]; tk[j] = tu;
            double pu = pf[i]; pf[i] = pf[j]; pf[j] = pu;
         }
      }
}

// Losers sorted worst-first; runners are always profitable so never appear here
int GetWorstLoss(int m, int maxN, ulong &outTk[], double &outPf[]) {
   int total = PositionsTotal();
   ulong  tk[]; ArrayResize(tk, total);
   double pf[]; ArrayResize(pf, total);
   int c = 0;
   for(int i = total - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != m) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      double pp = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(pp >= 0) continue;
      tk[c] = t; pf[c] = pp; c++;
   }
   SortPairsByPnl(tk, pf, c, true);
   int n = MathMin(c, maxN);
   ArrayResize(outTk, n); ArrayResize(outPf, n);
   for(int i = 0; i < n; i++) { outTk[i] = tk[i]; outPf[i] = pf[i]; }
   return n;
}

// Profitable positions sorted best-first; skipRun=true excludes runners
int GetBestProfit(int m, int maxN, ulong &outTk[], double &outPf[], bool skipRun=true) {
   int total = PositionsTotal();
   ulong  tk[]; ArrayResize(tk, total);
   double pf[]; ArrayResize(pf, total);
   int c = 0;
   for(int i = total - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != m) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(skipRun && IsRunner(t)) continue;
      double pp = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(pp <= 0) continue;
      tk[c] = t; pf[c] = pp; c++;
   }
   SortPairsByPnl(tk, pf, c, false);
   int n = MathMin(c, maxN);
   ArrayResize(outTk, n); ArrayResize(outPf, n);
   for(int i = 0; i < n; i++) { outTk[i] = tk[i]; outPf[i] = pf[i]; }
   return n;
}

bool CloseByTicket(ulong tk) {
   if(!PositionSelectByTicket(tk)) return false;
   int m = (int)PositionGetInteger(POSITION_MAGIC);
   return TR(m).PositionClose(tk, -1);
}

void CM(int m) {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != m) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      TR(m).PositionClose(tk, -1);
   }
}

bool IsRunner(ulong tk) {
   for(int i = 0; i < ArraySize(gRunTk1); i++) if(gRunTk1[i] == tk) return true;
   for(int i = 0; i < ArraySize(gRunTk3); i++) if(gRunTk3[i] == tk) return true;
   return false;
}

bool HasPositionNearPrice(int m, int dir, double price, int gsPts) {
   double zone = gsPts * _Point;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != m) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      int pd = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      if(pd != dir) continue;
      if(MathAbs(PositionGetDouble(POSITION_PRICE_OPEN) - price) < zone) return true;
   }
   return false;
}

void ApplyBESL(ulong tk, int offsetPts) {
   if(!PositionSelectByTicket(tk)) return;
   double op  = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl  = PositionGetDouble(POSITION_SL);
   double tp0 = PositionGetDouble(POSITION_TP);
   int    d   = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
   double nsl = op + d * offsetPts * _Point;
   bool better = (d == 1) ? (nsl > sl || sl == 0) : (nsl < sl || sl == 0);
   if(better) TR((int)PositionGetInteger(POSITION_MAGIC)).PositionModify(tk, nsl, tp0);
}

//+------------------------------------------------------------------+
//| ADX                                                              |
//+------------------------------------------------------------------+
int ADXDir() {
   if(!UseADX || hADX == INVALID_HANDLE) return 0;
   double adx[], pdi[], mdi[];
   ArraySetAsSeries(adx, true); ArraySetAsSeries(pdi, true); ArraySetAsSeries(mdi, true);
   if(CopyBuffer(hADX, 0, 0, 2, adx) < 2) return 0;
   if(CopyBuffer(hADX, 1, 0, 2, pdi) < 2) return 0;
   if(CopyBuffer(hADX, 2, 0, 2, mdi) < 2) return 0;
   if(adx[0] < ADXMin) return 0;
   return (pdi[0] > mdi[0]) ? 1 : -1;
}

//+------------------------------------------------------------------+
//| Daily lot tracking                                               |
//+------------------------------------------------------------------+
void ChkDayRollover() {
   datetime dayStart = iTime(_Symbol, PERIOD_D1, 0);
   if(dayStart != gTodayStart) {
      gTodayStart = dayStart;
      gDailyLot1 = gDailyLot2 = gDailyLot3 = 0.0;
   }
}

void RestoreDailyLots() {
   gTodayStart = iTime(_Symbol, PERIOD_D1, 0);
   gDailyLot1 = gDailyLot2 = gDailyLot3 = 0.0;
   if(!HistorySelect(gTodayStart, TimeCurrent())) return;
   for(int i = 0; i < HistoryDealsTotal(); i++) {
      ulong deal = HistoryDealGetTicket(i);
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol) continue;
      if((int)HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_IN) continue;
      int    m   = (int)HistoryDealGetInteger(deal, DEAL_MAGIC);
      double vol = HistoryDealGetDouble(deal, DEAL_VOLUME);
      if(m == MAGIC_1)      gDailyLot1 += vol;
      else if(m == MAGIC_2) gDailyLot2 += vol;
      else if(m == MAGIC_3) gDailyLot3 += vol;
   }
}

//+------------------------------------------------------------------+
//| Open Order                                                       |
//+------------------------------------------------------------------+
bool OO(int m, int dir, double lot) {
   if(!SpreadOK()) return false;
   double price = (dir == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                              : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int gs = (m == MAGIC_1) ? GS1 : (m == MAGIC_2) ? GS2 : GS3;
   if(HasPositionNearPrice(m, dir, price, gs)) return false;
   CTrade* tr = TR(m);
   bool ok = (dir == 1) ? tr.Buy(lot,  _Symbol, 0, 0, 0, "M" + IntegerToString(m))
                        : tr.Sell(lot, _Symbol, 0, 0, 0, "M" + IntegerToString(m));
   if(ok) {
      if(m == MAGIC_1)      gDailyLot1 += lot;
      else if(m == MAGIC_2) gDailyLot2 += lot;
      else                  gDailyLot3 += lot;
   } else {
      PrintFormat("[OO] FAIL M%d dir=%d err=%d", m, dir, GetLastError());
   }
   return ok;
}

//+------------------------------------------------------------------+
//| TP — CORE LOGIC                                                  |
//|                                                                  |
//| Condition  : closeable GP (non-runner winners ranked below       |
//|              SKCount survivors) >= required target               |
//| Absorption : close up to AbsorbN worst losers (0 = all           |
//|              affordable) — only if GP still covers req after     |
//| Execute    : close absorbed losers → close closeable winners →   |
//|              apply BE SL to SKCount survivors                    |
//|                                                                  |
//| Safety     : realized net = closeableGP − absorbedLoss >= req   |
//|              this is guaranteed by the absorption loop condition |
//+------------------------------------------------------------------+

// Sum of non-runner winners ranked below top SKCount survivors for magic m
double GetCloseableGP(int m) {
   ulong pTk[]; double pPf[];
   int nP = GetBestProfit(m, 999, pTk, pPf);
   double gp = 0;
   for(int i = SKCount; i < nP; i++) gp += pPf[i];
   return gp;
}

// Single-magic TP
bool DoTP(int m, double req) {
   // Collect non-runner winners for this magic (sorted best-first)
   ulong pTk[]; double pPf[];
   int nP = GetBestProfit(m, 999, pTk, pPf);

   // closeableGP = sum of winners ranked SKCount and below (survivors excluded)
   double closeableGP = 0;
   for(int i = SKCount; i < nP; i++) closeableGP += pPf[i];
   if(closeableGP < req) return false;

   // Collect losers sorted worst-first
   ulong lTk[]; double lPf[];
   int nL = GetWorstLoss(m, 9999, lTk, lPf);

   // Absorb up to AbsorbN losers while keeping closeableGP >= req + absorbed
   int cap = (AbsorbN > 0) ? MathMin(AbsorbN, nL) : nL;
   int absN = 0;
   double runLoss = 0;
   for(int i = 0; i < cap; i++) {
      double d = runLoss + MathAbs(lPf[i]);
      if(closeableGP < req + d) break;
      runLoss = d; absN++;
   }

   // Execute: losers first, then winners, then BE on survivors
   for(int i = 0; i < absN; i++) CloseByTicket(lTk[i]);
   for(int i = SKCount; i < nP; i++) CloseByTicket(pTk[i]);
   if(SKCount > 0 && SKBEPts > 0)
      for(int i = 0; i < MathMin(SKCount, nP); i++) ApplyBESL(pTk[i], SKBEPts);

   return true;
}

// Multi-magic TP: SKCount survivors per magic; losers absorbed globally (worst-first across all magics)
bool DoTPMulti(int &mgs[], double req) {
   int nm = ArraySize(mgs);
   if(nm == 0) return false;

   // Combined closeable GP across all magics
   double totalCloseableGP = 0;
   for(int mi = 0; mi < nm; mi++) totalCloseableGP += GetCloseableGP(mgs[mi]);
   if(totalCloseableGP < req) return false;

   // Collect all losers across all magics, sort worst-first globally
   ulong allLTk[]; double allLPf[];
   ArrayResize(allLTk, 0); ArrayResize(allLPf, 0);
   for(int mi = 0; mi < nm; mi++) {
      ulong lTk[]; double lPf[];
      int n = GetWorstLoss(mgs[mi], 9999, lTk, lPf);
      for(int j = 0; j < n; j++) {
         int sz = ArraySize(allLTk);
         ArrayResize(allLTk, sz+1); ArrayResize(allLPf, sz+1);
         allLTk[sz] = lTk[j]; allLPf[sz] = lPf[j];
      }
   }
   int totalL = ArraySize(allLTk);
   SortPairsByPnl(allLTk, allLPf, totalL, true);   // worst-first globally

   // Absorb up to AbsorbN worst losers while keeping totalCloseableGP >= req + absorbed
   int cap = (AbsorbN > 0) ? MathMin(AbsorbN, totalL) : totalL;
   int absN = 0;
   double runLoss = 0;
   for(int i = 0; i < cap; i++) {
      double d = runLoss + MathAbs(allLPf[i]);
      if(totalCloseableGP < req + d) break;
      runLoss = d; absN++;
   }

   // Close absorbed losers
   for(int i = 0; i < absN; i++) CloseByTicket(allLTk[i]);

   // Per-magic: close non-survivor winners, apply BE to SKCount survivors
   for(int mi = 0; mi < nm; mi++) {
      ulong pTk[]; double pPf[];
      int nP = GetBestProfit(mgs[mi], 999, pTk, pPf);
      for(int i = SKCount; i < nP; i++) CloseByTicket(pTk[i]);
      if(SKCount > 0 && SKBEPts > 0)
         for(int i = 0; i < MathMin(SKCount, nP); i++) ApplyBESL(pTk[i], SKBEPts);
   }

   return true;
}

//+------------------------------------------------------------------+
//| TP priority dispatcher                                           |
//|                                                                  |
//| Priority 1 — TotTP  : M1 + M2 + M3 combined >= TPTot           |
//| Priority 2 — PairTP : best qualifying 2-magic combo >= TPPair   |
//|              checks M1+M2, M1+M3, M2+M3; fires highest GP pair  |
//| Priority 3 — SepTP  : each magic individually >= TP1/TP2/TP3   |
//|                                                                  |
//| Higher priority fires first; lower levels run only if higher    |
//| didn't fire, preventing M1 profit being consumed by SepTP       |
//| before PairTP can use it to offset M3 losses.                   |
//+------------------------------------------------------------------+
void ChkAllTP() {
   // ── Priority 1: TotTP ────────────────────────────────────────────
   if(UseTotTP) {
      double gp = GetCloseableGP(MAGIC_1)+GetCloseableGP(MAGIC_2)+GetCloseableGP(MAGIC_3);
      if(gp >= TPTot) {
         int mgs[] = {MAGIC_1, MAGIC_2, MAGIC_3};
         if(DoTPMulti(mgs, TPTot)) return;
      }
   }

   // ── Priority 2: PairTP — any 2-magic combination ─────────────────
   if(UsePairTP) {
      // All 3 possible pairs
      int p1[3]; p1[0]=MAGIC_1; p1[1]=MAGIC_1; p1[2]=MAGIC_2;
      int p2[3]; p2[0]=MAGIC_2; p2[1]=MAGIC_3; p2[2]=MAGIC_3;

      // Find qualifying pair with highest combined closeable GP
      int    bestIdx = -1;
      double bestGP  = 0;
      for(int pi = 0; pi < 3; pi++) {
         double gp = GetCloseableGP(p1[pi]) + GetCloseableGP(p2[pi]);
         if(gp >= TPPair && gp > bestGP) { bestGP = gp; bestIdx = pi; }
      }
      if(bestIdx >= 0) {
         int mgs[2]; mgs[0] = p1[bestIdx]; mgs[1] = p2[bestIdx];
         if(DoTPMulti(mgs, TPPair)) return;
      }
   }

   // ── Priority 3: SepTP ────────────────────────────────────────────
   if(UseSepTP) {
      if(En1 && Count(MAGIC_1) > 0) DoTP(MAGIC_1, TP1);
      if(En2 && Count(MAGIC_2) > 0) DoTP(MAGIC_2, TP2);
      if(En3 && Count(MAGIC_3) > 0) DoTP(MAGIC_3, TP3);
   }
}

//+------------------------------------------------------------------+
//| TP All — close all non-runner positions when combined net >= TPAll|
//+------------------------------------------------------------------+
void ChkTPAll() {
   if(!UseTPAll) return;
   double p = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(IsRunner(tk)) continue;
      p += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   if(p < TPAll) return;
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(IsRunner(tk)) continue;
      CloseByTicket(tk);
   }
}

//+------------------------------------------------------------------+
//| Runner system                                                    |
//+------------------------------------------------------------------+
void UpdateRunners() {
   ArrayResize(gRunTk1, 0);
   if(RunKeepN1 > 0 && En1) {
      ulong pTk[]; double pPf[];
      int n = GetBestProfit(MAGIC_1, RunKeepN1, pTk, pPf, false);
      ArrayResize(gRunTk1, n);
      for(int i = 0; i < n; i++) gRunTk1[i] = pTk[i];
      if(n >= RunKeepN1 && RunBEPts > 0)
         for(int i = 0; i < n; i++) ApplyBESL(gRunTk1[i], RunBEPts);
   }
   ArrayResize(gRunTk3, 0);
   if(RunKeepN3 > 0 && En3) {
      ulong pTk[]; double pPf[];
      int n = GetBestProfit(MAGIC_3, RunKeepN3, pTk, pPf, false);
      ArrayResize(gRunTk3, n);
      for(int i = 0; i < n; i++) gRunTk3[i] = pTk[i];
      if(n >= RunKeepN3 && RunBEPts > 0)
         for(int i = 0; i < n; i++) ApplyBESL(gRunTk3[i], RunBEPts);
   }
}

void ChkRunTP() {
   if(RunKeepN1 > 0 && ArraySize(gRunTk1) > 0) {
      double rPNL = 0;
      for(int i = 0; i < ArraySize(gRunTk1); i++) {
         if(!PositionSelectByTicket(gRunTk1[i])) continue;
         rPNL += PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      }
      if(rPNL >= TPRun1)
         for(int i = 0; i < ArraySize(gRunTk1); i++) CloseByTicket(gRunTk1[i]);
   }
   if(RunKeepN3 > 0 && ArraySize(gRunTk3) > 0) {
      double rPNL = 0;
      for(int i = 0; i < ArraySize(gRunTk3); i++) {
         if(!PositionSelectByTicket(gRunTk3[i])) continue;
         rPNL += PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      }
      if(rPNL >= TPRun3)
         for(int i = 0; i < ArraySize(gRunTk3); i++) CloseByTicket(gRunTk3[i]);
   }
}

//+------------------------------------------------------------------+
//| BPK Breakeven                                                    |
//+------------------------------------------------------------------+
void ChkBPK() {
   if(!UseBPK) return;
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      double pp = PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      if(pp < BPKMinProfit) continue;
      ApplyBESL(tk, BPKBEPts);
   }
}

//+------------------------------------------------------------------+
//| Grid                                                             |
//+------------------------------------------------------------------+
double GridLot(int m, int level) {
   double base = (m==MAGIC_1)?Lot1:(m==MAGIC_2)?Lot2:Lot3;
   double mult = (m==MAGIC_1)?LotMult1:(m==MAGIC_2)?LotMult2:LotMult3;
   return NLot(base * MathPow(mult, (double)level));
}

// M1: BUY grid bidirectional — add BUY each time price moves GS1 pts in either
// direction from the last BUY open price
void ChkGrid1() {
   if(!En1) return;
   if(gTrig.active && gTrig.stoppedMagic == MAGIC_1) return;
   int cnt = Count(MAGIC_1);
   if(cnt >= MaxGrid1) return;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(cnt == 0) { if(OO(MAGIC_1, 1, GridLot(MAGIC_1, 0))) gLastBuy = ask; return; }
   if(gLastBuy > 0 && MathAbs(ask - gLastBuy) >= GS1 * _Point)
      if(OO(MAGIC_1, 1, GridLot(MAGIC_1, cnt))) gLastBuy = ask;
}

// M3: SELL grid bidirectional — add SELL each time price moves GS3 pts in either direction
void ChkGrid3() {
   if(!En3) return;
   if(gTrig.active && gTrig.stoppedMagic == MAGIC_3) return;
   int cnt = Count(MAGIC_3);
   if(cnt >= MaxGrid3) return;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(cnt == 0) { if(OO(MAGIC_3, -1, GridLot(MAGIC_3, 0))) gLastSell = bid; return; }
   if(gLastSell > 0 && MathAbs(bid - gLastSell) >= GS3 * _Point)
      if(OO(MAGIC_3, -1, GridLot(MAGIC_3, cnt))) gLastSell = bid;
}

// M2: ADX-directed in normal mode; counter-trend assist when trigger active
void ChkM2() {
   if(!En2) return;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int dir = 0;
   if(gTrig.active) {
      if(gTrig.stoppedMagic == MAGIC_1)
         dir = (bid >= gTrig.trigPrice) ? 1 : -1;
      else
         dir = (ask <= gTrig.trigPrice) ? -1 : 1;
   } else {
      dir = gADXDir;
   }
   if(dir == 0) return;
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != MAGIC_2) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      int pd = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      if(pd != dir) { CM(MAGIC_2); return; }
   }
   int cnt = Count(MAGIC_2);
   if(cnt >= MaxGrid2) return;
   OO(MAGIC_2, dir, GridLot(MAGIC_2, cnt));
}

//+------------------------------------------------------------------+
//| Loss Trigger                                                     |
//+------------------------------------------------------------------+
void ChkTrigger() {
   if(!gTrig.active) {
      if(TimeCurrent() < gTrigCoolEnd) return;
      if(En1 && Count(MAGIC_1) > 0) {
         double pnl1 = PNL(MAGIC_1);
         if(pnl1 <= -LossTrig1) {
            gTrig.active = true; gTrig.stoppedMagic = MAGIC_1;
            gTrig.trigPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            PrintFormat("[Trigger] M1 PNL=%.2f  trig=%.5f", pnl1, gTrig.trigPrice);
            CM(MAGIC_2); return;
         }
      }
      if(En3 && Count(MAGIC_3) > 0) {
         double pnl3 = PNL(MAGIC_3);
         if(pnl3 <= -LossTrig3) {
            gTrig.active = true; gTrig.stoppedMagic = MAGIC_3;
            gTrig.trigPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            PrintFormat("[Trigger] M3 PNL=%.2f  trig=%.5f", pnl3, gTrig.trigPrice);
            CM(MAGIC_2); return;
         }
      }
   } else {
      if(PNL(gTrig.stoppedMagic) >= 0) {
         PrintFormat("[Trigger] M%d recovered", gTrig.stoppedMagic == MAGIC_1 ? 1 : 3);
         gTrig.active = false; gTrig.stoppedMagic = 0; gTrig.trigPrice = 0.0;
         gTrigCoolEnd = TimeCurrent() + TrigCoolSec;
         CM(MAGIC_2);
      }
   }
}

//+------------------------------------------------------------------+
//| Panel helpers                                                    |
//+------------------------------------------------------------------+
int GetPanelX() {
   int cw = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
   return MathMax(5, cw - PanelX - PW_OUT);
}

double TotalLot(int m) {
   double v = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != m) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      v += PositionGetDouble(POSITION_VOLUME);
   }
   return v;
}

//+------------------------------------------------------------------+
//| Panel primitives                                                 |
//+------------------------------------------------------------------+
void Rect(string n, int x, int y, int w, int h, color bg, color brd) {
   if(ObjectFind(0, n) < 0) ObjectCreate(0, n, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_XSIZE, w);        ObjectSetInteger(0, n, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, n, OBJPROP_BGCOLOR, bg);     ObjectSetInteger(0, n, OBJPROP_COLOR, brd);
   ObjectSetInteger(0, n, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, n, OBJPROP_BACK, false);     ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
}

void Lbl(string n, int x, int y, string t, color c, int fs, string font="Arial Bold") {
   if(ObjectFind(0, n) < 0) ObjectCreate(0, n, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetString (0, n, OBJPROP_TEXT, t);         ObjectSetString (0, n, OBJPROP_FONT, font);
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE, fs);    ObjectSetInteger(0, n, OBJPROP_COLOR, c);
   ObjectSetInteger(0, n, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
   ObjectSetInteger(0, n, OBJPROP_BACK, false);     ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
}

void DeletePanel() { ObjectsDeleteAll(0, PFX); }

color PnlClr(double v) {
   if(v >  0.005) return CL_POS;
   if(v < -0.005) return CL_NEG;
   return CL_NEU;
}

string TFStr(ENUM_TIMEFRAMES tf) {
   switch(tf) {
      case PERIOD_M1:  return "M1";  case PERIOD_M5:  return "M5";
      case PERIOD_M15: return "M15"; case PERIOD_M30: return "M30";
      case PERIOD_H1:  return "H1";  case PERIOD_H4:  return "H4";
      case PERIOD_D1:  return "D1";  case PERIOD_W1:  return "W1";
      case PERIOD_MN1: return "MN";  default:          return "";
   }
}

void Bar(string id, int x, int y, int totalW, int h, int cnt, int maxCnt, color acClr) {
   Rect(PFX+id+"_BG", x, y, totalW, h, CB_BAR_BG, CB_BAR_BG);
   int fw = (maxCnt > 0 && cnt > 0)
            ? MathMax(2, MathMin(totalW, (int)MathRound((double)cnt/maxCnt*totalW))) : 0;
   Rect(PFX+id+"_FG", x, y, (fw>0?fw:1), h, (fw>0?acClr:CB_BAR_BG), (fw>0?acClr:CB_BAR_BG));
}

//+------------------------------------------------------------------+
//| Magic section row (M1 / M3)                                      |
//+------------------------------------------------------------------+
void DrawMagicSec(string id, int xi, int sy,
                  color acClr, color bgClr,
                  string tag, string statusTxt, color statusClr,
                  int cnt, int maxCnt,
                  int runCnt, int runMax,
                  double pnl, double openLot) {
   Rect(PFX+id+"_BG",  xi,   sy, PW_IN,   MSEC_H, bgClr, bgClr);
   Rect(PFX+id+"_ACC", xi,   sy, 5,       MSEC_H, acClr, acClr);
   Rect(PFX+id+"_HI",  xi+5, sy, PW_IN-5, 1,      C'20,28,52', C'20,28,52');

   int r1 = sy+7;
   Lbl(PFX+id+"_TAG", xi+13,  r1, tag,       acClr,     FN);
   Lbl(PFX+id+"_STA", xi+37,  r1, statusTxt, statusClr, FN);

   string runTxt = StringFormat("★%d/%d", runCnt, runMax);
   color  runClr = (runCnt >= runMax) ? CL_GOLD : (runCnt > 0 ? C'200,170,60' : CL_INFO);
   Lbl(PFX+id+"_RUN", xi+128, r1, runTxt, runClr, FS, "Arial");

   Bar(id, xi+172, r1+1, 96, 8, cnt, maxCnt, acClr);
   Lbl(PFX+id+"_CNT", xi+274, r1, StringFormat("%d/%d", cnt, maxCnt), CL_INFO, FS, "Courier New");

   int r2 = sy+28;
   Lbl(PFX+id+"_PL", xi+13,  r2, "PNL",                             CL_INFO,        FS,  "Arial");
   Lbl(PFX+id+"_PV", xi+37,  r2, StringFormat("%+.2f $", pnl),       PnlClr(pnl),    FN);
   Lbl(PFX+id+"_LL", xi+160, r2, "Open",                            CL_INFO,        FXS, "Arial");
   Lbl(PFX+id+"_LV", xi+193, r2, StringFormat("%.2f lot", openLot),  CL_CYAN,        FN);
}

//+------------------------------------------------------------------+
//| M2 row                                                           |
//+------------------------------------------------------------------+
void DrawM2Row(int xi, int sy, string modeTxt, color modeClr,
               int cnt, int maxCnt, double pnl) {
   Rect(PFX+"M2_BG",  xi,   sy, PW_IN,   M2R_H, CB_M2, CB_M2);
   Rect(PFX+"M2_ACC", xi,   sy, 5,       M2R_H, CA_M2, CA_M2);
   Rect(PFX+"M2_HI",  xi+5, sy, PW_IN-5, 1,     C'20,28,52', C'20,28,52');

   int r1 = sy+8;
   Lbl(PFX+"M2_TAG", xi+13,  r1, "M2",                              CA_M2,       FN);
   Lbl(PFX+"M2_MOD", xi+37,  r1, modeTxt,                           modeClr,     FN);
   Lbl(PFX+"M2_CNT", xi+210, r1, StringFormat("%d/%d", cnt, maxCnt), CL_INFO,    FS,  "Courier New");
   Lbl(PFX+"M2_PNL", xi+252, r1, StringFormat("%+.2f", pnl),         PnlClr(pnl), FN);
}

//+------------------------------------------------------------------+
//| Trigger banner                                                   |
//+------------------------------------------------------------------+
void DrawTrigBanner(int xi, int sy, int bw) {
   string line1, line2;
   color  bgClr, txtClr1, txtClr2;

   if(gTrig.active) {
      int    stoppedNum = (gTrig.stoppedMagic == MAGIC_1) ? 1 : 3;
      string helpDir    = (gTrig.stoppedMagic == MAGIC_1) ? "SELL" : "BUY";
      line1   = StringFormat("⛔  M%d STOPPED  |  M2 → %s assist", stoppedNum, helpDir);
      line2   = StringFormat("Trigger price: %s",
                   DoubleToString(gTrig.trigPrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
      bgClr   = C'40,10,12'; txtClr1 = CL_NEG; txtClr2 = C'200,120,120';
   } else if(TimeCurrent() < gTrigCoolEnd) {
      int sec = (int)(gTrigCoolEnd - TimeCurrent());
      line1   = StringFormat("◷  COOLDOWN  %d sec", sec);
      line2   = "Monitoring for re-arm...";
      bgClr   = C'38,30,8'; txtClr1 = C'255,185,50'; txtClr2 = C'180,140,60';
   } else {
      line1   = "✔   NORMAL MODE  —  ALL RUNNING";
      line2   = "M1 ↕ BUY grid  |  M3 ↕ SELL grid  |  M2 ADX";
      bgClr   = C'8,28,18'; txtClr1 = CL_POS; txtClr2 = C'60,140,90';
   }

   Rect(PFX+"TRIG_BG", xi, sy, bw, TRIG_H, bgClr, bgClr);
   Rect(PFX+"TRIG_LB", xi, sy, 4, TRIG_H,
        gTrig.active ? CL_NEG : (TimeCurrent()<gTrigCoolEnd ? C'255,185,50' : CL_POS),
        gTrig.active ? CL_NEG : (TimeCurrent()<gTrigCoolEnd ? C'255,185,50' : CL_POS));
   Lbl(PFX+"TRIG_L1", xi+10, sy+5,  line1, txtClr1, FN);
   Lbl(PFX+"TRIG_L2", xi+10, sy+20, line2, txtClr2, FXS, "Arial");
}

//+------------------------------------------------------------------+
//| Dashboard                                                        |
//+------------------------------------------------------------------+
void ShowDashboard() {
   if(!ShowPanel) return;
   if(MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE)) return;

   int px = GetPanelX();
   int py = PanelY;
   int xi = px + 3;

   double p1 = PNL(MAGIC_1), p2 = PNL(MAGIC_2), p3 = PNL(MAGIC_3);
   int    c1 = Count(MAGIC_1), c2 = Count(MAGIC_2), c3 = Count(MAGIC_3);
   double l1 = TotalLot(MAGIC_1), l2 = TotalLot(MAGIC_2), l3 = TotalLot(MAGIC_3);
   double lDay   = gDailyLot1 + gDailyLot2 + gDailyLot3;
   double tot    = p1 + p2 + p3;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double bal    = AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal > gBalanceHigh) gBalanceHigh = bal;
   double dd  = (gBalanceHigh > 0 && equity < gBalanceHigh)
                ? (gBalanceHigh - equity) / gBalanceHigh * 100.0 : 0.0;
   int    spd = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   int r1cnt = ArraySize(gRunTk1);
   int r3cnt = ArraySize(gRunTk3);

   bool   m1stopped = (gTrig.active && gTrig.stoppedMagic == MAGIC_1);
   string m1sta     = m1stopped ? "⛔ STOP" : "↕ BUY";
   color  m1clr     = m1stopped ? CL_NEG   : C'140,205,255';

   bool   m3stopped = (gTrig.active && gTrig.stoppedMagic == MAGIC_3);
   string m3sta     = m3stopped ? "⛔ STOP" : "↕ SELL";
   color  m3clr     = m3stopped ? CL_NEG   : C'255,195,130';

   string m2mod; color m2mClr;
   if(gTrig.active) {
      if(gTrig.stoppedMagic == MAGIC_1) { m2mod = "▼ SELL  ← assist M1"; m2mClr = C'255,130,130'; }
      else                               { m2mod = "▲ BUY   ← assist M3"; m2mClr = C'130,200,255'; }
   } else if(gADXDir ==  1) { m2mod = "▲ BUY   (ADX trend)"; m2mClr = C'130,200,255'; }
   else if(gADXDir == -1)   { m2mod = "▼ SELL  (ADX trend)"; m2mClr = C'255,130,130'; }
   else                     { m2mod = "■ IDLE  (ADX flat)";  m2mClr = CL_NEU;         }

   int PH = 3+HDR_H+2+TRIG_H+1+MSEC_H+1+M2R_H+1+MSEC_H+2+STAT_H+3;

   Rect(PFX+"BORDER", px, py,   PW_OUT, PH,   CB_BORDER, CB_BORDER);
   Rect(PFX+"BG",     xi, py+3, PW_IN,  PH-6, CB_BG,     CB_BG);

   int hy = py+3;
   Rect(PFX+"H_BG",   xi,     hy,       PW_IN, HDR_H, CB_HDR,        CB_HDR);
   Rect(PFX+"H_TOP",  xi,     hy,       PW_IN, 2,     C'60,100,200', C'60,100,200');
   Rect(PFX+"H_LINE", xi,     hy+HDR_H, PW_IN, 2,     CB_HDR_LN,     CB_HDR_LN);
   Lbl(PFX+"H_TXT",   xi+12,  hy+8,  "⚡  HYBRID PRO  V"+EA_VER,   CL_GOLD,        FH);
   Lbl(PFX+"H_STF",   xi+235, hy+10, _Symbol+" · "+TFStr(_Period),  C'100,125,170', FS, "Arial");

   int ty  = hy + HDR_H + 2;
   DrawTrigBanner(xi, ty, PW_IN);

   int sy1  = ty + TRIG_H + 1;
   int s12  = sy1 + MSEC_H;
   int sy2  = s12 + 1;
   int s23  = sy2 + M2R_H;
   int sy3  = s23 + 1;
   int sBri = sy3 + MSEC_H;
   int stY  = sBri + 2;

   Rect(PFX+"SEP12",  xi, s12,  PW_IN, 1, CB_SEP,    CB_SEP);
   Rect(PFX+"SEP23",  xi, s23,  PW_IN, 1, CB_SEP,    CB_SEP);
   Rect(PFX+"SEPBRI", xi, sBri, PW_IN, 2, CB_SEP_HI, CB_SEP_HI);

   DrawMagicSec("M1", xi, sy1, CA_M1, CB_M1, "M1", m1sta, m1clr,
                c1, MaxGrid1, r1cnt, RunKeepN1, p1, l1);
   DrawM2Row(xi, sy2, m2mod, m2mClr, c2, MaxGrid2, p2);
   DrawMagicSec("M3", xi, sy3, CA_M3, CB_M3, "M3", m3sta, m3clr,
                c3, MaxGrid3, r3cnt, RunKeepN3, p3, l3);

   Rect(PFX+"ST_BG", xi, stY, PW_IN, STAT_H, CB_STAT,   CB_STAT);
   Rect(PFX+"ST_HI", xi, stY, PW_IN, 1,      CB_SEP_HI, CB_SEP_HI);
   Rect(PFX+"VDIV",  xi+156, stY+4, 1, STAT_H-8, C'28,36,62', C'28,36,62');

   int cl  = xi+10;
   int sr1 = stY+6;
   Lbl(PFX+"FL_L",  cl,    sr1, "FLOAT",                     CL_INFO,      FS,  "Arial");
   Lbl(PFX+"FL_V",  cl+48, sr1, StringFormat("%+.2f $", tot), PnlClr(tot), 11);

   int sr2 = stY+23;
   color ddClr = (dd >= 10) ? CL_NEG : (dd >= 5) ? C'255,165,0' : CL_NEU;
   Lbl(PFX+"DD_L",  cl,    sr2, "DD",                        CL_INFO,  FS, "Arial");
   Lbl(PFX+"DD_V",  cl+22, sr2, StringFormat("%.2f%%", dd),  ddClr,    FN);

   int sr3 = stY+39;
   string adxTxt; color adxClr;
   if(!UseADX || hADX == INVALID_HANDLE) { adxTxt = "ADX OFF";   adxClr = C'70,80,110'; }
   else if(gADXDir ==  1)                { adxTxt = "ADX ▲ UP";  adxClr = CL_POS;       }
   else if(gADXDir == -1)                { adxTxt = "ADX ▼ DN";  adxClr = CL_NEG;       }
   else                                  { adxTxt = "ADX ▬ --";  adxClr = CL_NEU;       }
   Lbl(PFX+"ADX_V", cl, sr3, adxTxt, adxClr, FN);

   int cr = xi+165;
   Lbl(PFX+"EQ_L",  cr,    sr1, "EQUITY",                           CL_INFO,   FS,  "Arial");
   Lbl(PFX+"EQ_V",  cr+52, sr1, StringFormat("$%.0f", equity),       CL_BRIGHT, FN);

   color spdClr = (spd > MaxSpread) ? CL_NEG : CL_NEU;
   Lbl(PFX+"SP_L",  cr,    sr2, "Spread",                           CL_INFO,  FS,  "Arial");
   Lbl(PFX+"SP_V",  cr+52, sr2, StringFormat("%d pt", spd),          spdClr,   FN);

   Lbl(PFX+"LD_L",  cr,    sr3, "Lot/Day",                          CL_INFO,  FS,  "Arial");
   Lbl(PFX+"LD_V",  cr+52, sr3, StringFormat("%.2f lot", lDay),      CL_CYAN,  FN);

   Lbl(PFX+"TIME",  xi+PW_IN-58, stY+STAT_H-13,
       TimeToString(TimeCurrent(), TIME_MINUTES), CL_TIME, FXS, "Arial");

   ChartRedraw();
}

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit() {
   datetime now = TimeCurrent();
   if(now > 0 && now >= StringToTime(EXPIRY_STR)) {
      Print("[Init] expired"); return INIT_FAILED;
   }
   T1.SetExpertMagicNumber(MAGIC_1); T1.SetDeviationInPoints(30);
   T2.SetExpertMagicNumber(MAGIC_2); T2.SetDeviationInPoints(30);
   T3.SetExpertMagicNumber(MAGIC_3); T3.SetDeviationInPoints(30);

   if(UseADX) {
      hADX = iADX(_Symbol, ADXTF, ADXPer);
      if(hADX == INVALID_HANDLE) Print("[Init] ADX handle fail");
   }

   gLastBuy = 0.0; gLastSell = 0.0;
   datetime latestBuyTime = 0, latestSellTime = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      int      m  = (int)PositionGetInteger(POSITION_MAGIC);
      double   op = PositionGetDouble(POSITION_PRICE_OPEN);
      datetime ot = (datetime)PositionGetInteger(POSITION_TIME);
      if(m == MAGIC_1 && PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
         { if(ot > latestBuyTime)  { latestBuyTime  = ot; gLastBuy  = op; } }
      if(m == MAGIC_3 && PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
         { if(ot > latestSellTime) { latestSellTime = ot; gLastSell = op; } }
   }

   gTrig.active = false; gTrig.stoppedMagic = 0; gTrig.trigPrice = 0.0;
   gTrigCoolEnd = 0; gADXDir = 0;
   ArrayResize(gRunTk1, 0); ArrayResize(gRunTk3, 0);
   gBalanceHigh = AccountInfoDouble(ACCOUNT_BALANCE);
   RestoreDailyLots();

   PrintFormat("[Init] HybridPro V%s  M1=%d M2=%d M3=%d",
               EA_VER, Count(MAGIC_1), Count(MAGIC_2), Count(MAGIC_3));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   if(hADX != INVALID_HANDLE) { IndicatorRelease(hADX); hADX = INVALID_HANDLE; }
   DeletePanel();
   Comment("");
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick() {
   gADXDir = ADXDir();
   double b = AccountInfoDouble(ACCOUNT_BALANCE);
   if(b > gBalanceHigh) gBalanceHigh = b;

   ChkDayRollover();
   UpdateRunners();      // designate runners before any TP reads IsRunner()

   ChkTrigger();
   ChkGrid1();
   ChkGrid3();
   ChkM2();

   ChkAllTP();           // TotTP → PairTP (best 2-magic combo) → SepTP
   ChkTPAll();           // close all non-runners when combined net >= TPAll
   ChkRunTP();           // separate TP for runner positions

   ChkBPK();
   ShowDashboard();
}
//+------------------------------------------------------------------+
