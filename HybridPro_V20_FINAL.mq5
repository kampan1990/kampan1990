//+------------------------------------------------------------------+
//| HybridPro_V20_FINAL.mq5                                         |
//| M1=BUY-only grid | M2=ADX dynamic | M3=SELL-only grid           |
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
input double Lot1         = 0.01;   // M1 base lot
input double Lot2         = 0.01;   // M2 base lot
input double Lot3         = 0.01;   // M3 base lot
input double LotMult1     = 1.0;    // M1 lot multiplier per grid level
input double LotMult3     = 1.0;    // M3 lot multiplier per grid level

input group "=== Grid Spacing (points) ==="
input int    GS1          = 100;    // M1 BUY grid spacing
input int    GS2          = 100;    // M2 grid spacing
input int    GS3          = 100;    // M3 SELL grid spacing

input group "=== Grid Limits ==="
input int    MaxGrid1     = 20;
input int    MaxGrid2     = 10;
input int    MaxGrid3     = 20;

input group "=== Loss Trigger ==="
input double LossTrig1    = 200.0;  // M1 stop threshold ($)
input double LossTrig3    = 200.0;  // M3 stop threshold ($)

input group "=== ADX ==="
input bool            UseADX  = true;
input ENUM_TIMEFRAMES ADXTF   = PERIOD_H1;
input int             ADXPer  = 14;
input double          ADXMin  = 20.0;

input group "=== Take Profit ==="
input bool   UseSepTP     = true;
input double TP1          = 5.0;    // M1 separate TP ($)
input double TP2          = 5.0;    // M2 separate TP ($)
input double TP3          = 5.0;    // M3 separate TP ($)
input bool   UseTotTP     = true;
input double TPTot        = 15.0;   // Total (M1+M2+M3) TP ($)
input bool   UsePairTP    = true;
input double TPPair       = 10.0;   // Pair (M1+M3) TP ($)
input int    SelfAbs      = 1;      // Worst-loss positions absorbed per TP round
input int    SKCount      = 1;      // SafeKeep positions after TP
input int    SKBEPts      = 5;      // SafeKeep BE SL offset (points)

input group "=== BPK Breakeven ==="
input bool   UseBPK       = false;
input double BPKMinProfit = 50.0;
input int    BPKBEPts     = 10;

input group "=== Spread ==="
input int    MaxSpread    = 50;

input group "=== Display ==="
input bool   ShowPanel    = true;

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade T1, T2, T3;
int    hADX      = INVALID_HANDLE;

TriggerState gTrig = {false, 0, 0.0};

double gLastBuy  = 0.0;  // lowest M1 BUY open price (most recent in downward grid)
double gLastSell = 0.0;  // highest M3 SELL open price (most recent in upward grid)

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

double GrossProfit(int m) {
   double p = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != m) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      double pp = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(pp > 0) p += pp;
   }
   return p;
}

// Returns up to maxN worst (most-negative) losing positions, sorted ascending
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

   for(int i = 0; i < c - 1; i++)
      for(int j = i + 1; j < c; j++)
         if(pf[j] < pf[i]) {
            ulong  tu = tk[i]; tk[i] = tk[j]; tk[j] = tu;
            double pu = pf[i]; pf[i] = pf[j]; pf[j] = pu;
         }

   int n = MathMin(c, maxN);
   ArrayResize(outTk, n); ArrayResize(outPf, n);
   for(int i = 0; i < n; i++) { outTk[i] = tk[i]; outPf[i] = pf[i]; }
   return n;
}

// Returns up to maxN best (most-positive) profitable positions, sorted descending
int GetBestProfit(int m, int maxN, ulong &outTk[], double &outPf[]) {
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
      if(pp <= 0) continue;
      tk[c] = t; pf[c] = pp; c++;
   }

   for(int i = 0; i < c - 1; i++)
      for(int j = i + 1; j < c; j++)
         if(pf[j] > pf[i]) {
            ulong  tu = tk[i]; tk[i] = tk[j]; tk[j] = tu;
            double pu = pf[i]; pf[i] = pf[j]; pf[j] = pu;
         }

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

// True if same magic+direction already has a position within gs points of price
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

//+------------------------------------------------------------------+
//| ADX                                                              |
//+------------------------------------------------------------------+
bool ADXTrendBuy() {
   if(!UseADX || hADX == INVALID_HANDLE) return true;
   double adx[], pdi[], mdi[];
   ArraySetAsSeries(adx, true);
   ArraySetAsSeries(pdi, true);
   ArraySetAsSeries(mdi, true);
   if(CopyBuffer(hADX, 0, 0, 2, adx) < 2) return true;
   if(CopyBuffer(hADX, 1, 0, 2, pdi) < 2) return true;
   if(CopyBuffer(hADX, 2, 0, 2, mdi) < 2) return true;
   return (adx[0] >= ADXMin && pdi[0] > mdi[0]);
}

bool ADXTrendSell() {
   if(!UseADX || hADX == INVALID_HANDLE) return true;
   double adx[], pdi[], mdi[];
   ArraySetAsSeries(adx, true);
   ArraySetAsSeries(pdi, true);
   ArraySetAsSeries(mdi, true);
   if(CopyBuffer(hADX, 0, 0, 2, adx) < 2) return true;
   if(CopyBuffer(hADX, 1, 0, 2, pdi) < 2) return true;
   if(CopyBuffer(hADX, 2, 0, 2, mdi) < 2) return true;
   return (adx[0] >= ADXMin && mdi[0] > pdi[0]);
}

//+------------------------------------------------------------------+
//| Open Order — spread + anti-bloat guard                           |
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
   if(!ok) PrintFormat("[OO] FAIL M%d dir=%d err=%d", m, dir, GetLastError());
   return ok;
}

//+------------------------------------------------------------------+
//| DoTP — single-magic TP with worst-loss absorption                |
//+------------------------------------------------------------------+
bool DoTP(int m, double req) {
   double gp = GrossProfit(m);
   if(gp <= 0) return false;

   ulong  lTk[]; double lPf[];
   double totalLoss = 0.0;
   int nLoss = 0;
   if(SelfAbs > 0) {
      nLoss = GetWorstLoss(m, SelfAbs, lTk, lPf);
      for(int i = 0; i < nLoss; i++) totalLoss += MathAbs(lPf[i]);
   }
   if(gp < req + totalLoss) return false;

   ulong pTk[]; double pPf[];
   int nP = GetBestProfit(m, 999, pTk, pPf);
   if(nP == 0) return false;

   for(int i = 0; i < nLoss; i++) CloseByTicket(lTk[i]);

   int closeN = nP - SKCount;
   if(closeN <= 0) return true;
   for(int i = 0; i < closeN; i++) CloseByTicket(pTk[i]);

   if(SKCount > 0 && SKBEPts > 0) {
      for(int i = closeN; i < nP; i++) {
         if(!PositionSelectByTicket(pTk[i])) continue;
         double op  = PositionGetDouble(POSITION_PRICE_OPEN);
         double sl  = PositionGetDouble(POSITION_SL);
         double tp0 = PositionGetDouble(POSITION_TP);
         int    d   = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
         double nsl = op + d * SKBEPts * _Point;
         bool better = (d == 1) ? (nsl > sl || sl == 0) : (nsl < sl || sl == 0);
         if(better) TR(m).PositionModify(pTk[i], nsl, tp0);
      }
   }
   return true;
}

//+------------------------------------------------------------------+
//| DoTPMulti — combined TP across multiple magics                   |
//+------------------------------------------------------------------+
bool DoTPMulti(int &mgs[], double req) {
   int nm = ArraySize(mgs);
   if(nm == 0) return false;

   double totalGP = 0;
   for(int mi = 0; mi < nm; mi++) totalGP += GrossProfit(mgs[mi]);
   if(totalGP <= 0) return false;

   ulong  allLTk[]; double allLPf[];
   ArrayResize(allLTk, 0); ArrayResize(allLPf, 0);

   if(SelfAbs > 0) {
      for(int mi = 0; mi < nm; mi++) {
         ulong lTk[]; double lPf[];
         int n = GetWorstLoss(mgs[mi], SelfAbs, lTk, lPf);
         for(int j = 0; j < n; j++) {
            int sz = ArraySize(allLTk);
            ArrayResize(allLTk, sz + 1); ArrayResize(allLPf, sz + 1);
            allLTk[sz] = lTk[j]; allLPf[sz] = lPf[j];
         }
      }
      int sz = ArraySize(allLTk);
      for(int i = 0; i < sz - 1; i++)
         for(int j = i + 1; j < sz; j++)
            if(allLPf[j] < allLPf[i]) {
               ulong  tu = allLTk[i]; allLTk[i] = allLTk[j]; allLTk[j] = tu;
               double pu = allLPf[i]; allLPf[i] = allLPf[j]; allLPf[j] = pu;
            }
      if(sz > SelfAbs) ArrayResize(allLTk, SelfAbs);
   }

   double totalLoss = 0;
   for(int i = 0; i < ArraySize(allLTk); i++) totalLoss += MathAbs(allLPf[i]);
   if(totalGP < req + totalLoss) return false;

   for(int i = 0; i < ArraySize(allLTk); i++) CloseByTicket(allLTk[i]);

   ulong  allPTk[]; double allPPf[];
   ArrayResize(allPTk, 0); ArrayResize(allPPf, 0);
   for(int mi = 0; mi < nm; mi++) {
      ulong pTk[]; double pPf[];
      int n = GetBestProfit(mgs[mi], 999, pTk, pPf);
      for(int j = 0; j < n; j++) {
         int sz = ArraySize(allPTk);
         ArrayResize(allPTk, sz + 1); ArrayResize(allPPf, sz + 1);
         allPTk[sz] = pTk[j]; allPPf[sz] = pPf[j];
      }
   }
   int psz = ArraySize(allPTk);
   for(int i = 0; i < psz - 1; i++)
      for(int j = i + 1; j < psz; j++)
         if(allPPf[j] > allPPf[i]) {
            ulong  tu = allPTk[i]; allPTk[i] = allPTk[j]; allPTk[j] = tu;
            double pu = allPPf[i]; allPPf[i] = allPPf[j]; allPPf[j] = pu;
         }

   int closeN = psz - SKCount;
   if(closeN <= 0) return true;
   for(int i = 0; i < closeN; i++) CloseByTicket(allPTk[i]);
   return true;
}

//+------------------------------------------------------------------+
//| TP Checks                                                        |
//+------------------------------------------------------------------+
void ChkSepTP() {
   if(!UseSepTP) return;
   if(En1 && Count(MAGIC_1) > 0) DoTP(MAGIC_1, TP1);
   if(En2 && Count(MAGIC_2) > 0) DoTP(MAGIC_2, TP2);
   if(En3 && Count(MAGIC_3) > 0) DoTP(MAGIC_3, TP3);
}

void ChkPairTP() {
   if(!UsePairTP) return;
   double pair = PNL(MAGIC_1) + PNL(MAGIC_3);
   if(pair < TPPair) return;
   int mgs[] = {MAGIC_1, MAGIC_3};
   DoTPMulti(mgs, TPPair);
}

void ChkTotTP() {
   if(!UseTotTP) return;
   double tot = PNL(MAGIC_1) + PNL(MAGIC_2) + PNL(MAGIC_3);
   if(tot < TPTot) return;
   int mgs[] = {MAGIC_1, MAGIC_2, MAGIC_3};
   DoTPMulti(mgs, TPTot);
}

//+------------------------------------------------------------------+
//| BPK Breakeven                                                    |
//+------------------------------------------------------------------+
void ChkBPK() {
   if(!UseBPK) return;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      double pp = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(pp < BPKMinProfit) continue;
      double op  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl  = PositionGetDouble(POSITION_SL);
      double tp0 = PositionGetDouble(POSITION_TP);
      int    d   = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      double nsl = op + d * BPKBEPts * _Point;
      bool better = (d == 1) ? (nsl > sl || sl == 0) : (nsl < sl || sl == 0);
      if(better) {
         int m = (int)PositionGetInteger(POSITION_MAGIC);
         TR(m).PositionModify(tk, nsl, tp0);
      }
   }
}

//+------------------------------------------------------------------+
//| Grid Lot                                                         |
//+------------------------------------------------------------------+
double GridLot(int m, int level) {
   double base = (m == MAGIC_1) ? Lot1 : (m == MAGIC_2) ? Lot2 : Lot3;
   double mult = (m == MAGIC_1) ? LotMult1 : (m == MAGIC_3) ? LotMult3 : 1.0;
   return NLot(base * MathPow(mult, (double)level));
}

//+------------------------------------------------------------------+
//| M1 BUY grid — opens first position, then adds every GS1 pts drop|
//+------------------------------------------------------------------+
void ChkGrid1() {
   if(!En1) return;
   if(gTrig.active && gTrig.stoppedMagic == MAGIC_1) return;

   int cnt = Count(MAGIC_1);
   if(cnt >= MaxGrid1) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(cnt == 0) {
      if(OO(MAGIC_1, 1, GridLot(MAGIC_1, 0))) gLastBuy = ask;
      return;
   }

   if(gLastBuy > 0 && gLastBuy - ask >= GS1 * _Point) {
      if(OO(MAGIC_1, 1, GridLot(MAGIC_1, cnt))) gLastBuy = ask;
   }
}

//+------------------------------------------------------------------+
//| M3 SELL grid — opens first position, then adds every GS3 pts rise|
//+------------------------------------------------------------------+
void ChkGrid3() {
   if(!En3) return;
   if(gTrig.active && gTrig.stoppedMagic == MAGIC_3) return;

   int cnt = Count(MAGIC_3);
   if(cnt >= MaxGrid3) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(cnt == 0) {
      if(OO(MAGIC_3, -1, GridLot(MAGIC_3, 0))) gLastSell = bid;
      return;
   }

   if(gLastSell > 0 && bid - gLastSell >= GS3 * _Point) {
      if(OO(MAGIC_3, -1, GridLot(MAGIC_3, cnt))) gLastSell = bid;
   }
}

//+------------------------------------------------------------------+
//| M2 Dynamic — ADX-driven; uses trigger to switch helping side     |
//+------------------------------------------------------------------+
void ChkM2() {
   if(!En2) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   int dir = 0;
   if(gTrig.active) {
      if(gTrig.stoppedMagic == MAGIC_1) {
         // M1 BUY stopped (price fell). Help M3 SELL until price climbs back above trigger.
         dir = (bid >= gTrig.trigPrice) ? 1 : -1;
      } else {
         // M3 SELL stopped (price rose). Help M1 BUY until price drops back below trigger.
         dir = (ask <= gTrig.trigPrice) ? -1 : 1;
      }
   } else {
      if(ADXTrendBuy())       dir =  1;
      else if(ADXTrendSell()) dir = -1;
   }
   if(dir == 0) return;

   // Close wrong-direction M2 positions and wait one tick before re-opening
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
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
//| Trigger — stops losing side; releases when it recovers           |
//+------------------------------------------------------------------+
void ChkTrigger() {
   if(!gTrig.active) {
      if(En1 && Count(MAGIC_1) > 0 && PNL(MAGIC_1) <= -LossTrig1) {
         gTrig.active       = true;
         gTrig.stoppedMagic = MAGIC_1;
         gTrig.trigPrice    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         PrintFormat("[Trigger] M1 PNL=%.2f  trigPrice=%.5f", PNL(MAGIC_1), gTrig.trigPrice);
         CM(MAGIC_2);
         return;
      }
      if(En3 && Count(MAGIC_3) > 0 && PNL(MAGIC_3) <= -LossTrig3) {
         gTrig.active       = true;
         gTrig.stoppedMagic = MAGIC_3;
         gTrig.trigPrice    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         PrintFormat("[Trigger] M3 PNL=%.2f  trigPrice=%.5f", PNL(MAGIC_3), gTrig.trigPrice);
         CM(MAGIC_2);
         return;
      }
   } else {
      if(PNL(gTrig.stoppedMagic) >= 0) {
         PrintFormat("[Trigger] M%d recovered — released",
                     gTrig.stoppedMagic == MAGIC_1 ? 1 : 3);
         gTrig = {false, 0, 0.0};
         CM(MAGIC_2);
      }
   }
}

//+------------------------------------------------------------------+
//| Dashboard                                                        |
//+------------------------------------------------------------------+
void ShowDashboard() {
   if(!ShowPanel) return;
   if(MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE)) return;

   double p1 = PNL(MAGIC_1), p2 = PNL(MAGIC_2), p3 = PNL(MAGIC_3);
   int    c1 = Count(MAGIC_1), c2 = Count(MAGIC_2), c3 = Count(MAGIC_3);

   string trigStr = "Normal";
   if(gTrig.active)
      trigStr = StringFormat("STOPPED M%d  Trig=%.5f",
                             gTrig.stoppedMagic == MAGIC_1 ? 1 : 3, gTrig.trigPrice);

   string adxStr = "ADX:OFF";
   if(UseADX && hADX != INVALID_HANDLE)
      adxStr = ADXTrendBuy() ? "ADX:UP" : ADXTrendSell() ? "ADX:DOWN" : "ADX:FLAT";

   Comment(StringFormat(
      "=== HybridPro V%s ===\n"
      "M1 BUY  %2d pos  PNL=%+.2f\n"
      "M2 DYN  %2d pos  PNL=%+.2f\n"
      "M3 SELL %2d pos  PNL=%+.2f\n"
      "TOTAL           PNL=%+.2f\n"
      "%s  |  %s",
      EA_VER, c1, p1, c2, p2, c3, p3, p1 + p2 + p3, trigStr, adxStr));
}

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit() {
   datetime now = TimeCurrent();
   if(now > 0 && now >= StringToTime(EXPIRY_STR)) {
      Print("[Init] EA expired"); return INIT_FAILED;
   }

   T1.SetExpertMagicNumber(MAGIC_1); T1.SetDeviationInPoints(30);
   T2.SetExpertMagicNumber(MAGIC_2); T2.SetDeviationInPoints(30);
   T3.SetExpertMagicNumber(MAGIC_3); T3.SetDeviationInPoints(30);

   if(UseADX) {
      hADX = iADX(_Symbol, ADXTF, ADXPer);
      if(hADX == INVALID_HANDLE)
         Print("[Init] ADX handle fail — ADX filter disabled");
   }

   // Restore grid price trackers from existing positions
   gLastBuy = 0.0; gLastSell = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      int    m  = (int)PositionGetInteger(POSITION_MAGIC);
      double op = PositionGetDouble(POSITION_PRICE_OPEN);
      if(m == MAGIC_1 && PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
         { if(gLastBuy  == 0 || op < gLastBuy)  gLastBuy  = op; }
      if(m == MAGIC_3 && PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
         { if(gLastSell == 0 || op > gLastSell) gLastSell = op; }
   }

   gTrig = {false, 0, 0.0};

   PrintFormat("[Init] HybridPro V%s OK  M1=%d M2=%d M3=%d  LastBuy=%.5f LastSell=%.5f",
               EA_VER, Count(MAGIC_1), Count(MAGIC_2), Count(MAGIC_3), gLastBuy, gLastSell);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   if(hADX != INVALID_HANDLE) { IndicatorRelease(hADX); hADX = INVALID_HANDLE; }
   Comment("");
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick() {
   ChkTrigger();   // evaluate loss triggers before any new orders

   ChkGrid1();     // M1 BUY grid
   ChkGrid3();     // M3 SELL grid — opens simultaneously with M1 on first tick

   ChkM2();        // M2 ADX dynamic helper

   ChkSepTP();     // separate TP per magic
   ChkPairTP();    // combined M1+M3 TP
   ChkTotTP();     // combined M1+M2+M3 TP

   ChkBPK();       // BPK breakeven SL
   ShowDashboard();
}
//+------------------------------------------------------------------+
