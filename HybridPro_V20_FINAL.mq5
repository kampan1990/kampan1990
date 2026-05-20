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
#define PFX        "HP_"

// ── Panel layout ────────────────────────────────────────────────────
#define PW_OUT   304   // outer width  (incl. 3px borders each side)
#define PW_IN    298   // inner content width
#define SEC_H     52   // height of each magic section
#define HDR_H     32   // header height
#define STAT_H    58   // stats section height

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

// ── Font sizes ────────────────────────────────────────────────────────
#define FH  10   // header
#define FN   9   // normal
#define FS   8   // small
#define FXS  7   // extra small

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
input double TP1          = 5.0;
input double TP2          = 5.0;
input double TP3          = 5.0;
input bool   UseTotTP     = true;
input double TPTot        = 15.0;
input bool   UsePairTP    = true;
input double TPPair       = 10.0;
input int    SelfAbs      = 0;   // max losers absorbed per TP (0=absorb all affordable)
input int    SKCount      = 1;
input int    SKBEPts      = 5;

input group "=== BPK Breakeven ==="
input bool   UseBPK       = false;
input double BPKMinProfit = 50.0;
input int    BPKBEPts     = 10;

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
int    hADX          = INVALID_HANDLE;
int    gADXDir       = 0;
datetime gTrigCoolEnd = 0;

TriggerState gTrig;

double gLastBuy  = 0.0;
double gLastSell = 0.0;

double   gDailyLot1  = 0.0;
double   gDailyLot2  = 0.0;
double   gDailyLot3  = 0.0;
datetime gTodayStart = 0;

double gBalanceHigh = 0.0;   // for DD% calculation

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
//| TP helpers                                                       |
//+------------------------------------------------------------------+
// Find how many losers (worst-first, already sorted) can be absorbed
// while keeping: grossProfit >= req + running_loss
// Cap: SelfAbs > 0 means max SelfAbs at a time; 0 = absorb all affordable
int CalcAbsorbN(double &lPf[], int total, double grossProfit, double req) {
   int cap = (SelfAbs > 0) ? SelfAbs : total;
   int n = 0;
   double running = 0.0;
   for(int i = 0; i < total && n < cap; i++) {
      double newRunning = running + MathAbs(lPf[i]);
      if(grossProfit < req + newRunning) break;
      running = newRunning;
      n++;
   }
   return n;
}

//+------------------------------------------------------------------+
//| TP                                                               |
//+------------------------------------------------------------------+
bool DoTP(int m, double req) {
   double gp = GrossProfit(m);
   if(gp < req) return false;
   // Collect ALL losers worst-first
   ulong lTk[]; double lPf[];
   int nAll = GetWorstLoss(m, 9999, lTk, lPf);
   int absN = CalcAbsorbN(lPf, nAll, gp, req);
   // absN=0 is OK if there are no losers — still take TP on winners
   ulong pTk[]; double pPf[];
   int nP = GetBestProfit(m, 999, pTk, pPf);
   if(nP == 0) return false;
   // Close affordable losers first (worst to least bad)
   for(int i = 0; i < absN; i++) CloseByTicket(lTk[i]);
   // Close winners (keep SKCount safest ones with BE SL)
   int closeN = nP - SKCount;
   if(closeN <= 0) return true;
   for(int i = 0; i < closeN; i++) CloseByTicket(pTk[i]);
   if(SKCount > 0 && SKBEPts > 0)
      for(int i = closeN; i < nP; i++) ApplyBESL(pTk[i], SKBEPts);
   return true;
}

bool DoTPMulti(int &mgs[], double req) {
   int nm = ArraySize(mgs); if(nm == 0) return false;
   double totalGP = 0;
   for(int mi = 0; mi < nm; mi++) totalGP += GrossProfit(mgs[mi]);
   if(totalGP < req) return false;
   // Collect ALL losers from all magics, sort worst-first
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
   SortPairsByPnl(allLTk, allLPf, totalL, true);  // worst first
   // Find how many we can absorb
   int absN = CalcAbsorbN(allLPf, totalL, totalGP, req);
   // Collect all profitable positions
   ulong allPTk[]; double allPPf[];
   ArrayResize(allPTk, 0); ArrayResize(allPPf, 0);
   for(int mi = 0; mi < nm; mi++) {
      ulong pTk[]; double pPf[];
      int n = GetBestProfit(mgs[mi], 999, pTk, pPf);
      for(int j = 0; j < n; j++) {
         int sz = ArraySize(allPTk);
         ArrayResize(allPTk, sz+1); ArrayResize(allPPf, sz+1);
         allPTk[sz] = pTk[j]; allPPf[sz] = pPf[j];
      }
   }
   if(ArraySize(allPTk) == 0) return false;
   // Execute: close losers then winners
   for(int i = 0; i < absN; i++) CloseByTicket(allLTk[i]);
   int psz = ArraySize(allPTk);
   SortPairsByPnl(allPTk, allPPf, psz, false);  // best-profit first
   int closeN = psz - SKCount;
   if(closeN <= 0) return true;
   for(int i = 0; i < closeN; i++) CloseByTicket(allPTk[i]);
   if(SKCount > 0 && SKBEPts > 0)
      for(int i = closeN; i < psz; i++) ApplyBESL(allPTk[i], SKBEPts);
   return true;
}

void ChkSepTP() {
   if(!UseSepTP) return;
   if(En1 && Count(MAGIC_1)>0) DoTP(MAGIC_1, TP1);
   if(En2 && Count(MAGIC_2)>0) DoTP(MAGIC_2, TP2);
   if(En3 && Count(MAGIC_3)>0) DoTP(MAGIC_3, TP3);
}
void ChkPairTP() {
   if(!UsePairTP) return;
   if(PNL(MAGIC_1)+PNL(MAGIC_3) < TPPair) return;
   int mgs[]={MAGIC_1,MAGIC_3}; DoTPMulti(mgs,TPPair);
}
void ChkTotTP() {
   if(!UseTotTP) return;
   if(PNL(MAGIC_1)+PNL(MAGIC_2)+PNL(MAGIC_3) < TPTot) return;
   int mgs[]={MAGIC_1,MAGIC_2,MAGIC_3}; DoTPMulti(mgs,TPTot);
}

void ChkBPK() {
   if(!UseBPK) return;
   for(int i = PositionsTotal()-1; i>=0; i--) {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      double pp = PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      if(pp < BPKMinProfit) continue;
      ApplyBESL(tk, BPKBEPts);
   }
}

double GridLot(int m, int level) {
   double base = (m==MAGIC_1)?Lot1:(m==MAGIC_2)?Lot2:Lot3;
   double mult = (m==MAGIC_1)?LotMult1:(m==MAGIC_2)?LotMult2:LotMult3;
   return NLot(base*MathPow(mult,(double)level));
}

void ChkGrid1() {
   if(!En1) return;
   if(gTrig.active && gTrig.stoppedMagic==MAGIC_1) return;
   int cnt=Count(MAGIC_1); if(cnt>=MaxGrid1) return;
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   if(cnt==0){ if(OO(MAGIC_1,1,GridLot(MAGIC_1,0))) gLastBuy=ask; return; }
   // Bidirectional: add BUY when price drops OR rises GS1 pts from last BUY
   if(gLastBuy>0 && MathAbs(ask-gLastBuy)>=GS1*_Point)
      if(OO(MAGIC_1,1,GridLot(MAGIC_1,cnt))) gLastBuy=ask;
}
void ChkGrid3() {
   if(!En3) return;
   if(gTrig.active && gTrig.stoppedMagic==MAGIC_3) return;
   int cnt=Count(MAGIC_3); if(cnt>=MaxGrid3) return;
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(cnt==0){ if(OO(MAGIC_3,-1,GridLot(MAGIC_3,0))) gLastSell=bid; return; }
   if(gLastSell>0 && bid-gLastSell>=GS3*_Point)
      if(OO(MAGIC_3,-1,GridLot(MAGIC_3,cnt))) gLastSell=bid;
}
void ChkM2() {
   if(!En2) return;
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   int dir=0;
   if(gTrig.active) {
      dir=(gTrig.stoppedMagic==MAGIC_1)?((bid>=gTrig.trigPrice)?1:-1):((ask<=gTrig.trigPrice)?-1:1);
   } else { dir=gADXDir; }
   if(dir==0) return;
   for(int i=PositionsTotal()-1;i>=0;i--) {
      ulong tk=PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC)!=MAGIC_2) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      int pd=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)?1:-1;
      if(pd!=dir){ CM(MAGIC_2); return; }
   }
   int cnt=Count(MAGIC_2); if(cnt>=MaxGrid2) return;
   OO(MAGIC_2,dir,GridLot(MAGIC_2,cnt));
}

void ChkTrigger() {
   if(!gTrig.active) {
      if(TimeCurrent()<gTrigCoolEnd) return;
      if(En1&&Count(MAGIC_1)>0){
         double pnl1=PNL(MAGIC_1);
         if(pnl1<=-LossTrig1){
            gTrig.active=true; gTrig.stoppedMagic=MAGIC_1;
            gTrig.trigPrice=SymbolInfoDouble(_Symbol,SYMBOL_BID);
            PrintFormat("[Trigger] M1 PNL=%.2f  trig=%.5f",pnl1,gTrig.trigPrice);
            CM(MAGIC_2); return;
         }
      }
      if(En3&&Count(MAGIC_3)>0){
         double pnl3=PNL(MAGIC_3);
         if(pnl3<=-LossTrig3){
            gTrig.active=true; gTrig.stoppedMagic=MAGIC_3;
            gTrig.trigPrice=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
            PrintFormat("[Trigger] M3 PNL=%.2f  trig=%.5f",pnl3,gTrig.trigPrice);
            CM(MAGIC_2); return;
         }
      }
   } else {
      if(PNL(gTrig.stoppedMagic)>=0){
         PrintFormat("[Trigger] M%d recovered",gTrig.stoppedMagic==MAGIC_1?1:3);
         gTrig.active=false; gTrig.stoppedMagic=0; gTrig.trigPrice=0.0;
         gTrigCoolEnd=TimeCurrent()+TrigCoolSec;
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

//+------------------------------------------------------------------+
//| Panel primitives                                                 |
//+------------------------------------------------------------------+
void Rect(string n,int x,int y,int w,int h,color bg,color brd) {
   if(ObjectFind(0,n)<0) ObjectCreate(0,n,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_XSIZE,w);        ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg);     ObjectSetInteger(0,n,OBJPROP_COLOR,brd);
   ObjectSetInteger(0,n,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0,n,OBJPROP_BACK,false);     ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
}
void Lbl(string n,int x,int y,string t,color c,int fs,string font="Arial Bold") {
   if(ObjectFind(0,n)<0) ObjectCreate(0,n,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetString (0,n,OBJPROP_TEXT,t);         ObjectSetString (0,n,OBJPROP_FONT,font);
   ObjectSetInteger(0,n,OBJPROP_FONTSIZE,fs);    ObjectSetInteger(0,n,OBJPROP_COLOR,c);
   ObjectSetInteger(0,n,OBJPROP_ANCHOR,ANCHOR_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_BACK,false);     ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
}
void DeletePanel() { ObjectsDeleteAll(0,PFX); }

color PnlClr(double v){
   if(v> 0.005) return CL_POS;
   if(v<-0.005) return CL_NEG;
   return CL_NEU;
}

string TFStr(ENUM_TIMEFRAMES tf) {
   switch(tf){
      case PERIOD_M1: return "M1"; case PERIOD_M5:  return "M5";
      case PERIOD_M15:return "M15";case PERIOD_M30: return "M30";
      case PERIOD_H1: return "H1"; case PERIOD_H4:  return "H4";
      case PERIOD_D1: return "D1"; case PERIOD_W1:  return "W1";
      case PERIOD_MN1:return "MN"; default:          return "";
   }
}

// Rectangle-based progress bar: background rect + filled rect
void DrawBar(string id, int px, int x, int y, int cnt, int maxCnt, color acClr) {
   int barW = 130;
   int barH = 9;
   Rect(PFX+id+"_PBG", px+x, y, barW, barH, CB_BAR_BG, CB_BAR_BG);
   int fillW = (maxCnt>0) ? MathMax(1, MathMin(barW, (int)MathRound((double)cnt/maxCnt*barW))) : 0;
   if(cnt>0 && fillW>0)
      Rect(PFX+id+"_PFG", px+x, y, fillW, barH, acClr, acClr);
   else
      Rect(PFX+id+"_PFG", px+x, y, 1, barH, CB_BAR_BG, CB_BAR_BG);
}

// Draw one complete magic section — px = GetPanelX() result
void DrawMagicSec(string id, int px, int sy,
                  color acClr, color bgClr,
                  string tag, string dirTxt, color dirClr,
                  int cnt, int maxCnt, double pnl, double lotDay) {
   int xi = px+3;
   Rect(PFX+id+"_BG",  xi,    sy,   PW_IN, SEC_H, bgClr,  bgClr);
   Rect(PFX+id+"_ACC", xi,    sy,   5,     SEC_H, acClr,  acClr);
   Rect(PFX+id+"_HI",  xi+5,  sy,   PW_IN-5, 1,   C'25,32,58', C'25,32,58');

   int r1 = sy+8;
   Lbl(PFX+id+"_TAG", xi+14, r1, tag,    acClr,    FN);
   Lbl(PFX+id+"_DIR", xi+40, r1, dirTxt, dirClr,   FN);
   DrawBar(id, xi, 118, r1, cnt, maxCnt, acClr);
   Lbl(PFX+id+"_CNT", xi+255, r1,
       StringFormat("%d/%d", cnt, maxCnt), CL_INFO, FS, "Courier New");

   int r2 = sy+30;
   Lbl(PFX+id+"_PNLL", xi+14, r2, "PNL",                     CL_INFO,    FS, "Arial");
   Lbl(PFX+id+"_PNLV", xi+40, r2, StringFormat("%+.2f $", pnl), PnlClr(pnl), FN);
   Lbl(PFX+id+"_LOTL", xi+158, r2, "Lot/Day",                 CL_INFO,    FXS, "Arial");
   Lbl(PFX+id+"_LOTV", xi+204, r2, StringFormat("%.2f",lotDay), CL_CYAN,   FN);
   Lbl(PFX+id+"_LOTU", xi+250, r2, "lot",                     CL_INFO,    FXS, "Arial");
}

//+------------------------------------------------------------------+
//| Dashboard                                                        |
//+------------------------------------------------------------------+
void ShowDashboard() {
   if(!ShowPanel) return;
   if(MQLInfoInteger(MQL_TESTER)&&!MQLInfoInteger(MQL_VISUAL_MODE)) return;

   int x  = GetPanelX();
   int y  = PanelY;
   int xi = x+3;   // inner X

   // ── Live data ──────────────────────────────────────────────────
   double p1=PNL(MAGIC_1), p2=PNL(MAGIC_2), p3=PNL(MAGIC_3);
   int    c1=Count(MAGIC_1), c2=Count(MAGIC_2), c3=Count(MAGIC_3);
   double tot   = p1+p2+p3;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double bal    = AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal>gBalanceHigh) gBalanceHigh=bal;
   double dd = (gBalanceHigh>0 && equity<gBalanceHigh)
               ? (gBalanceHigh-equity)/gBalanceHigh*100.0 : 0.0;
   int spd = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);

   // ── Total panel height ──────────────────────────────────────────
   // outer 3px border + hdr32 + 3×(sec52+sep1) + stat58 + 3px border
   // = 3 + 32 + 2 + 3*(52+1) + 58 + 3 = 257
   int PH = 3+HDR_H+2+3*(SEC_H+1)+STAT_H+3;  // = 257

   // ── Outer border ───────────────────────────────────────────────
   Rect(PFX+"BORDER", x,   y,   PW_OUT, PH,   CB_BORDER, CB_BORDER);
   Rect(PFX+"BG",     xi,  y+3, PW_IN,  PH-6, CB_BG,     CB_BG);

   // ── Header ─────────────────────────────────────────────────────
   int hy = y+3;
   Rect(PFX+"HDR_BG",   xi,  hy,      PW_IN, HDR_H,   CB_HDR,    CB_HDR);
   Rect(PFX+"HDR_TOP",  xi,  hy,      PW_IN, 1,       C'70,108,210', C'70,108,210');
   Rect(PFX+"HDR_LINE", xi,  hy+HDR_H,PW_IN, 2,       CB_HDR_LN, CB_HDR_LN);
   Lbl(PFX+"HDR_TXT",  xi+12, hy+9, "⚡  HYBRID PRO  V"+EA_VER, CL_GOLD, FH);
   string stf = _Symbol+" • "+TFStr(_Period);
   Lbl(PFX+"HDR_STF",  xi+220, hy+11, stf, C'125,145,180', FS, "Arial");

   // ── Magic sections ─────────────────────────────────────────────
   int sy1 = hy+HDR_H+2;
   int sy2 = sy1+SEC_H+1;
   int sy3 = sy2+SEC_H+1;

   Rect(PFX+"SEP1", xi, sy1+SEC_H, PW_IN, 1, CB_SEP, CB_SEP);
   Rect(PFX+"SEP2", xi, sy2+SEC_H, PW_IN, 1, CB_SEP, CB_SEP);
   Rect(PFX+"SEP3", xi, sy3+SEC_H, PW_IN, 2, CB_SEP_HI, CB_SEP_HI);

   // M2 direction
   string m2dir; color m2clr;
   if     (gADXDir== 1){ m2dir="▲ BUY";  m2clr=C'135,175,255'; }
   else if(gADXDir==-1){ m2dir="▼ SELL"; m2clr=C'255,145,145'; }
   else                 { m2dir="■ IDLE"; m2clr=C'110,115,140'; }

   DrawMagicSec("M1", x, sy1, CA_M1, CB_M1,
                "M1", "▲ BUY",  C'165,208,255', c1, MaxGrid1, p1, gDailyLot1);
   DrawMagicSec("M2", x, sy2, CA_M2, CB_M2,
                "M2", m2dir,     m2clr,          c2, MaxGrid2, p2, gDailyLot2);
   DrawMagicSec("M3", x, sy3, CA_M3, CB_M3,
                "M3", "▼ SELL", C'255,195,135', c3, MaxGrid3, p3, gDailyLot3);

   // ── Stats section ──────────────────────────────────────────────
   int stY = sy3+SEC_H+2;
   Rect(PFX+"STAT_BG", xi, stY, PW_IN, STAT_H, CB_STAT, CB_STAT);

   // Row 1 — Total float + Equity
   int sr1 = stY+6;
   Lbl(PFX+"TOT_L",  xi+12, sr1, "FLOAT",                    CL_INFO,  FS, "Arial");
   Lbl(PFX+"TOT_V",  xi+52, sr1, StringFormat("%+.2f $", tot), PnlClr(tot), 11);
   Rect(PFX+"VDIV1", xi+162, sr1+1, 1, 22, C'30,38,65', C'30,38,65');
   Lbl(PFX+"EQ_L",   xi+170, sr1, "EQUITY",                   CL_INFO,  FS, "Arial");
   Lbl(PFX+"EQ_V",   xi+212, sr1, StringFormat("$%.0f", equity), CL_BRIGHT, FN);

   // Row 2 — DD + Spread
   int sr2 = stY+26;
   color ddClr = (dd>=10)?CL_NEG:(dd>=5)?C'255,165,0':CL_NEU;
   Lbl(PFX+"DD_L",   xi+12, sr2, "Drawdown",               CL_INFO,  FS, "Arial");
   Lbl(PFX+"DD_V",   xi+68, sr2, StringFormat("%.2f%%",dd), ddClr,    FN);
   Rect(PFX+"VDIV2", xi+162, sr2+1, 1, 20, C'30,38,65', C'30,38,65');
   Lbl(PFX+"SPD_L",  xi+170, sr2, "Spread",                 CL_INFO,  FS, "Arial");
   color spdClr=(spd>MaxSpread)?CL_NEG:CL_NEU;
   Lbl(PFX+"SPD_V",  xi+212, sr2, StringFormat("%d pts",spd), spdClr,  FN);

   // Row 3 — ADX + Trigger/Status
   int sr3 = stY+44;
   string adxTxt; color adxClr;
   if(!UseADX||hADX==INVALID_HANDLE){ adxTxt="ADX ■ OFF";   adxClr=C'80,90,115';  }
   else if(gADXDir== 1)             { adxTxt="ADX ▲ UP";    adxClr=CL_POS;         }
   else if(gADXDir==-1)             { adxTxt="ADX ▼ DOWN";  adxClr=CL_NEG;         }
   else                              { adxTxt="ADX ▬ FLAT";  adxClr=CL_NEU;         }
   Lbl(PFX+"ADX_V", xi+12, sr3, adxTxt, adxClr, FN);

   string trigTxt; color trigClr;
   if(gTrig.active){
      trigTxt=StringFormat("⛔ M%d STOP", gTrig.stoppedMagic==MAGIC_1?1:3);
      trigClr=CL_NEG;
   } else if(TimeCurrent()<gTrigCoolEnd){
      trigTxt=StringFormat("◷ COOL %ds",(int)(gTrigCoolEnd-TimeCurrent()));
      trigClr=C'255,165,0';
   } else {
      trigTxt="✔ Running";
      trigClr=CL_POS;
   }
   Lbl(PFX+"TRIG_V", xi+170, sr3, trigTxt, trigClr, FN);

   // Footer timestamp
   Lbl(PFX+"TIME", xi+PW_IN-62, stY+STAT_H-14,
       TimeToString(TimeCurrent(), TIME_MINUTES), CL_TIME, FXS, "Arial");

   ChartRedraw();
}

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit() {
   datetime now = TimeCurrent();
   if(now>0 && now>=StringToTime(EXPIRY_STR)){ Print("[Init] expired"); return INIT_FAILED; }
   T1.SetExpertMagicNumber(MAGIC_1); T1.SetDeviationInPoints(30);
   T2.SetExpertMagicNumber(MAGIC_2); T2.SetDeviationInPoints(30);
   T3.SetExpertMagicNumber(MAGIC_3); T3.SetDeviationInPoints(30);
   if(UseADX){
      hADX=iADX(_Symbol,ADXTF,ADXPer);
      if(hADX==INVALID_HANDLE) Print("[Init] ADX handle fail");
   }
   gLastBuy=0.0; gLastSell=0.0;
   datetime latestBuyTime=0, latestSellTime=0;
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong tk=PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      int m=(int)PositionGetInteger(POSITION_MAGIC);
      double op=PositionGetDouble(POSITION_PRICE_OPEN);
      datetime ot=(datetime)PositionGetInteger(POSITION_TIME);
      // M1 bidirectional: restore as most-recently opened position
      if(m==MAGIC_1&&PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)
         { if(ot>latestBuyTime){ latestBuyTime=ot; gLastBuy=op; } }
      // M3 upward grid: restore as most-recently opened position
      if(m==MAGIC_3&&PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_SELL)
         { if(ot>latestSellTime){ latestSellTime=ot; gLastSell=op; } }
   }
   gTrig.active=false; gTrig.stoppedMagic=0; gTrig.trigPrice=0.0;
   gTrigCoolEnd=0; gADXDir=0;
   gBalanceHigh=AccountInfoDouble(ACCOUNT_BALANCE);
   RestoreDailyLots();
   PrintFormat("[Init] HybridPro V%s  M1=%d M2=%d M3=%d",
               EA_VER,Count(MAGIC_1),Count(MAGIC_2),Count(MAGIC_3));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason){
   if(hADX!=INVALID_HANDLE){ IndicatorRelease(hADX); hADX=INVALID_HANDLE; }
   DeletePanel(); Comment("");
}

void OnTick(){
   gADXDir=ADXDir();
   double b=AccountInfoDouble(ACCOUNT_BALANCE);
   if(b>gBalanceHigh) gBalanceHigh=b;
   ChkDayRollover();
   ChkTrigger();
   ChkGrid1(); ChkGrid3(); ChkM2();
   ChkSepTP(); ChkPairTP(); ChkTotTP();
   ChkBPK();
   ShowDashboard();
}
//+------------------------------------------------------------------+
