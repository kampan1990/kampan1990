//+------------------------------------------------------------------+
//|  HybridPro_V20_FINAL.mq5                                        |
//|  Version 20.00 — Single file, no includes except Trade.mqh      |
//+------------------------------------------------------------------+
#property version "20.00"
#property strict
#include <Trade\Trade.mqh>

#define EA_VER      "20.00"
#define EXPIRY_STR  "2026.12.31 23:59"

//--- Enums
enum ENUM_ADX_COND    { ADX_ANY=0, ADX_TREND=1, ADX_SIDE=2 };
enum ENUM_M2_MODE     { M2_BIDIR=0, M2_ONEWAY=1 };
enum ENUM_M1M3_MODE   { M13_ONEWAY=0, M13_TWOWAY=1 };
enum ENUM_GTARGET     { GT_NONE=0, GT_M1=1111, GT_M3=3333 };

//--- Structs
struct RoundState {
   bool     active;
   int      dir;
   int      cnt;
   double   lastPrice;
   datetime sigTime;
   double   lastBuyP;
   double   lastSellP;
};

struct GuardState {
   bool     active;
   ENUM_GTARGET target;
   int      dir;           // ทิศทางที่ M2+helper ออก (สวน victim)
   double   trigPrice;     // ราคา ณ ที่ trigger
   double   lastPrice;
   int      cnt;
   datetime startT;
   datetime lastOrderT;
   int      totalAbs;
   bool     victimStopped; // victim หยุดออกออเดอร์ชั่วคราวโดย Guardian
   bool     reversed;      // กราฟกลับมาถึง trigPrice แล้ว (switch phase)
   bool     resumeMode;    // กราฟเลย trigPrice+100pts → M1/M2 ช่วยกัน
   double   resumePrice;   // ราคาที่จะเริ่ม resumeMode
};

struct BPKSlot {
   ulong  ticket;
   int    magic;
   int    dir;
   double profit;
   bool   valid;
};

//+------------------------------------------------------------------+
//| พารามิเตอร์ตั้งค่า                                              |
//+------------------------------------------------------------------+

input group "=== หมายเลข Magic ==="
input int  MAGIC_1 = 1111; // Magic หมายเลข 1
input int  MAGIC_2 = 2222; // Magic หมายเลข 2
input int  MAGIC_3 = 3333; // Magic หมายเลข 3

input group "=== เปิด/ปิด Magic ==="
input bool En1 = true;  // เปิดใช้ Magic 1
input bool En2 = true;  // เปิดใช้ Magic 2
input bool En3 = true;  // เปิดใช้ Magic 3

input group "=== การตั้งค่า Grid ==="
input ENUM_M1M3_MODE GridMode13 = M13_TWOWAY; // โหมด Grid ของ M1 และ M3
input bool           LinkM1M3   = true;        // เชื่อมทิศทาง M1 ↔ M3 (M3 สวนทาง M1)
input ENUM_M2_MODE   M2Mode     = M2_BIDIR;    // โหมด Grid ของ M2
input int            GS1        = 100;          // ระยะ Grid M1 (points)
input int            GS2        = 100;          // ระยะ Grid M2 (points)
input int            GS3        = 100;          // ระยะ Grid M3 (points)

input group "=== ขนาด Lot และความเสี่ยง ==="
input double BaseLot   = 0.01;  // Lot พื้นฐาน
input bool   UseComp   = true;  // เปิดใช้ Compounding ตาม Equity
input double CL1       = 10000.0; // Equity ขั้นที่ 1 (บาท/$)
input double CLot1     = 0.01;    // Lot ที่ Equity ขั้นที่ 1
input double CL2       = 40000.0; // Equity ขั้นที่ 2
input double CLot2     = 0.02;    // Lot ที่ Equity ขั้นที่ 2
input double CL3       = 120000.0;// Equity ขั้นที่ 3
input double CLot3     = 0.04;    // Lot ที่ Equity ขั้นที่ 3
input double RecScale  = 1.0;   // ตัวคูณ Lot เมื่อ Recovery (1.0 = คงที่)
input int    RecEvery  = 2;     // เพิ่ม Lot ทุกกี่ไม้ Recovery

input group "=== จำกัดจำนวน Position และ Spread ==="
input int MaxPerMagic = 400;  // จำนวน Position สูงสุดต่อ Magic
input int MaxTotal    = 500;  // จำนวน Position สูงสุดรวมทุก Magic
input int MaxSpread   = 1000; // Spread สูงสุดที่ยอมรับ (points)
input int Slip        = 10;   // Slippage สูงสุด (points)

input group "=== ฟิลเตอร์ ADX ==="
input bool            UseADX   = false;          // เปิดใช้ฟิลเตอร์ ADX
input ENUM_TIMEFRAMES ADXTF    = PERIOD_CURRENT; // Timeframe ของ ADX
input int             ADXPer   = 14;             // Period ของ ADX
input double          ADXThr   = 25.0;           // ค่า Threshold ADX (Trend/Sideways)
input ENUM_ADX_COND   ADXCond1 = ADX_TREND;      // เงื่อนไข ADX สำหรับ M1
input ENUM_ADX_COND   ADXCond2 = ADX_SIDE;       // เงื่อนไข ADX สำหรับ M2
input ENUM_ADX_COND   ADXCond3 = ADX_TREND;      // เงื่อนไข ADX สำหรับ M3

input group "=== สัญญาณ Multi-Timeframe ==="
input bool            UseMTF = false;       // เปิดใช้ Signal แยก Timeframe ต่อ Magic
input ENUM_TIMEFRAMES TF1    = PERIOD_M1;   // Timeframe สัญญาณ M1
input ENUM_TIMEFRAMES TF2    = PERIOD_M5;   // Timeframe สัญญาณ M2
input ENUM_TIMEFRAMES TF3    = PERIOD_M5;   // Timeframe สัญญาณ M3

input group "=== Take Profit แยกรายตัว ==="
input bool   UseSepTP = true;  // เปิดใช้ TP แยกรายตัว
input double TP1      = 20.0;  // เป้ากำไร Magic 1 ($)
input double TP2      = 20.0;  // เป้ากำไร Magic 2 ($)
input double TP3      = 20.0;  // เป้ากำไร Magic 3 ($)

input group "=== Take Profit รวมทุก Magic ==="
input bool   UseTotTP = true;  // เปิดใช้ TP รวมทุก Magic
input double TPAll    = 10.0;  // เป้ากำไรรวมทุก Magic ($)

input group "=== Take Profit คู่ Magic ==="
input bool   UseTwoTP = true;  // เปิดใช้ TP คู่ Magic
input double TPTwo    = 15.0;  // เป้ากำไรรวม 2 Magic ($)

input group "=== Safe Keep (เก็บไม้กำไรไว้หลัง TP) ==="
input int    SKCount  = 2;    // จำนวนไม้กำไรที่เก็บไว้หลัง TP
input double SKBE     = 0.0;  // ระยะ Breakeven SL ของไม้ที่เก็บ (points, 0=ที่ราคาเปิด)
input int    SelfAbs  = 2;    // จำนวนไม้ขาดทุนที่ดึงเข้ากลุ่ม TP ทุกรอบ

input group "=== Smart DD Absorption (แปลง DD เป็น Debt) ==="
input bool   UseDDA    = true;  // เปิดใช้ Smart DD Absorption
input double DDA1      = 10.0;  // DD% ระดับ 1 ที่เริ่ม Absorb
input int    DDACnt1   = 2;     // จำนวนไม้ที่ Absorb ที่ระดับ 1
input double DDA2      = 20.0;  // DD% ระดับ 2
input int    DDACnt2   = 4;     // จำนวนไม้ที่ Absorb ที่ระดับ 2
input double DDA3      = 30.0;  // DD% ระดับ 3
input int    DDACnt3   = 8;     // จำนวนไม้ที่ Absorb ที่ระดับ 3
input int    DDACool   = 30;    // Cooldown ระหว่าง Absorb (วินาที)

input group "=== Best Position Keeper (BPK) ==="
input bool   UseBPK    = true;   // เปิดใช้ BPK (ปกป้องไม้กำไรที่ดีที่สุด)
input int    BPKBuy    = 1;      // จำนวน Slot ไม้ BUY ที่ปกป้อง
input int    BPKSell   = 1;      // จำนวน Slot ไม้ SELL ที่ปกป้อง
input double BPKBuyTP  = 50.0;   // เป้ากำไรรวม BUY Slot ($) ก่อนปิด
input double BPKSellTP = 50.0;   // เป้ากำไรรวม SELL Slot ($) ก่อนปิด
input double BPKMinP   = 0.0;    // กำไรขั้นต่ำของไม้ที่จะเข้า Slot ($)
input int    BPKBEPts  = 10;     // ระยะ BE SL ของ BPK นับจากราคาเปิด (points, 0=ที่ราคาเปิดพอดี)

input group "=== Guardian System ==="
input bool   UseGuard   = true;   // เปิดใช้ Guardian System
input double GTrig1     = 50.0;   // ขาดทุน M1 ที่กระตุ้น Guardian ($)
input double GTrig3     = 50.0;   // ขาดทุน M3 ที่กระตุ้น Guardian ($)
input int    GAbsCnt    = 4;      // จำนวนไม้ขาดทุน victim ที่ดึงออกเมื่อ Guardian TP
input double GNetTP     = 20.0;   // กำไรสุทธิที่ต้องการหลังดูดซับ ($)
input int    GStep      = 0;      // ระยะ Grid ของ Guardian M2 (0=ใช้ค่า GS2)
input int    GCool      = 10;     // Cooldown ระหว่างเปิดไม้ Guardian (วินาที)
input int    GResumeOfs = 100;    // จำนวน points เลย trigPrice ถึงจะ resume M1+M2
input int    GInitCnt   = 3;      // จำนวนไม้ M2 ที่เปิดพร้อมกันตอนเริ่ม Guardian (ทุก Phase)

input group "=== Re-Open หลัง TP (เปิดไม้ใหม่ตำแหน่งดีหลังเคลียไม้เสีย) ==="
input bool   UseReOpen  = true;  // เปิดใช้ Re-Open หลัง TP ทุกรอบ
input bool   ROGuardOnly = true; // Re-Open เฉพาะตอน Guardian ทำงานเท่านั้น
input int    RODelay    = 0;     // หน่วงก่อน Re-Open (วินาที, 0=ทันที)

//+------------------------------------------------------------------+
//| GLOBALS                                                          |
//+------------------------------------------------------------------+
CTrade T1,T2,T3;
int    hATR=INVALID_HANDLE, hADX=INVALID_HANDLE;
double gATR=0,gADX=0,gPeak=0,gMaxDD=0;
double gD1=0,gD2=0,gD3=0,gDG=0;
datetime gLastAbs=0;
int gs1,gs2,gs3;

RoundState sM1,sM2,sM3;
GuardState gG;

BPKSlot gBB[],gBS[];
double  gBBTP=0,gBSTP=0;
int     gBBC=0,gBSC=0;

datetime gBar=0,gBarM1=0,gBarM2=0;

datetime gROTime1=0, gROTime2=0, gROTime3=0;
int      gRODir1=0,  gRODir2=0,  gRODir3=0;

//+------------------------------------------------------------------+
//| HELPERS                                                          |
//+------------------------------------------------------------------+
double NLot(double v){
   double s=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP),mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),mx=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   v=MathFloor(v/s)*s; if(v<mn)v=mn; if(v>mx)v=mx; return NormalizeDouble(v,2);
}
double Lot(int n){
   double b=BaseLot;
   if(UseComp){double e=AccountInfoDouble(ACCOUNT_EQUITY);if(e>=CL3)b=CLot3;else if(e>=CL2)b=CLot2;else if(e>=CL1)b=CLot1;}
   if(n<=2)return NLot(b);
   return NLot(b*MathPow(RecScale,(int)MathFloor((double)(n-1)/(double)RecEvery)));
}
double DD(){
   if(gPeak<=0)return 0;
   double d=(gPeak-AccountInfoDouble(ACCOUNT_EQUITY))/gPeak*100.0;
   return d>0?d:0;
}
void RR(RoundState &s){s.active=false;s.dir=0;s.cnt=0;s.lastPrice=0;s.sigTime=0;s.lastBuyP=0;s.lastSellP=0;}
void SR(RoundState &s,bool a,int d,double p,datetime t){s.active=a;s.dir=d;s.cnt=0;s.lastPrice=p;s.sigTime=t;s.lastBuyP=p;s.lastSellP=p;}
CTrade* TR(int m){if(m==MAGIC_1)return &T1;if(m==MAGIC_2)return &T2;return &T3;}

bool IsBPK(ulong t){
   if(!UseBPK)return false;
   for(int i=0;i<ArraySize(gBB);i++)if(gBB[i].valid&&gBB[i].ticket==t)return true;
   for(int i=0;i<ArraySize(gBS);i++)if(gBS[i].valid&&gBS[i].ticket==t)return true;
   return false;
}

int CP(int m){
   int c=0;
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong t=PositionGetTicket(i);
      if(PositionSelectByTicket(t)&&PositionGetInteger(POSITION_MAGIC)==m&&PositionGetString(POSITION_SYMBOL)==_Symbol)c++;
   }
   return c;
}
int CNB(int m){
   int c=0;
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t))continue;
      if(PositionGetInteger(POSITION_MAGIC)!=m||PositionGetString(POSITION_SYMBOL)!=_Symbol)continue;
      if(!IsBPK(t))c++;
   }
   return c;
}
double PNL(int m){
   double p=0;
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong t=PositionGetTicket(i);
      if(PositionSelectByTicket(t)&&PositionGetInteger(POSITION_MAGIC)==m&&PositionGetString(POSITION_SYMBOL)==_Symbol)
         p+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
   }
   return p;
}
double PNLNB(int m){
   double p=0;
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t))continue;
      if(PositionGetInteger(POSITION_MAGIC)!=m||PositionGetString(POSITION_SYMBOL)!=_Symbol)continue;
      if(!IsBPK(t))p+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
   }
   return p;
}

double GrossProfitNB(int m){
   double p=0;
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t))continue;
      if(PositionGetInteger(POSITION_MAGIC)!=m||PositionGetString(POSITION_SYMBOL)!=_Symbol)continue;
      if(IsBPK(t))continue;
      double pnl=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      if(pnl>0)p+=pnl;
   }
   return p;
}

double TotalLossNB(int m){
   double p=0;
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t))continue;
      if(PositionGetInteger(POSITION_MAGIC)!=m||PositionGetString(POSITION_SYMBOL)!=_Symbol)continue;
      if(IsBPK(t))continue;
      double pnl=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      if(pnl<0)p+=MathAbs(pnl);
   }
   return p;
}

int GetWorstLoss(int m, int n, ulong &outTk[], double &outPf[])
{
   ulong  tk[]; double pf[]; int c=0;
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t))continue;
      if(PositionGetInteger(POSITION_MAGIC)!=m||PositionGetString(POSITION_SYMBOL)!=_Symbol)continue;
      if(IsBPK(t))continue;
      double p=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      if(p<0){ArrayResize(tk,c+1);ArrayResize(pf,c+1);tk[c]=t;pf[c]=p;c++;}
   }
   for(int i=0;i<c-1;i++)for(int j=i+1;j<c;j++)if(pf[j]<pf[i]){double x=pf[i];pf[i]=pf[j];pf[j]=x;ulong u=tk[i];tk[i]=tk[j];tk[j]=u;}
   int take=MathMin(n,c);
   ArrayResize(outTk,take);ArrayResize(outPf,take);
   for(int i=0;i<take;i++){outTk[i]=tk[i];outPf[i]=pf[i];}
   return take;
}

double WLoss(int m,int n){
   if(n<=0)return 0;
   ulong tk[];double pf[];int c=GetWorstLoss(m,n,tk,pf);
   double s=0;for(int i=0;i<c;i++)s+=MathAbs(pf[i]);
   return s;
}
int CW(int m,int n){
   if(n<=0)return 0;
   CTrade*tr=TR(m);
   ulong tk[];double pf[];int c=GetWorstLoss(m,n,tk,pf);
   int cl=0;for(int i=0;i<c;i++)if(tr.PositionClose(tk[i]))cl++;
   return cl;
}
void CM(int m,bool force=false){
   CTrade*tr=TR(m);
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t))continue;
      if(PositionGetInteger(POSITION_MAGIC)!=m||PositionGetString(POSITION_SYMBOL)!=_Symbol)continue;
      if(!force&&IsBPK(t))continue;
      tr.PositionClose(t);
   }
}
bool SpreadOK(){return(int)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD)<=MaxSpread;}
bool ADXOk(int m){
   if(!UseADX)return true;
   ENUM_ADX_COND c=(m==MAGIC_1)?ADXCond1:(m==MAGIC_2)?ADXCond2:ADXCond3;
   if(c==ADX_ANY)return true;
   return(c==ADX_TREND)?(gADX>ADXThr):(gADX<ADXThr);
}
bool IsVic(int m){return UseGuard&&gG.active&&(int)gG.target==m;}

bool IsVictimStopped(int m){
   if(!UseGuard||!gG.active)return false;
   if((int)gG.target!=m)return false;
   return gG.victimStopped;
}

bool CanP(int m){
   if(m==MAGIC_1&&!En1)return false;
   if(m==MAGIC_2&&!En2)return false;
   if(m==MAGIC_3&&!En3)return false;
   int c1=En1?CP(MAGIC_1):0,c2=En2?CP(MAGIC_2):0,c3=En3?CP(MAGIC_3):0;
   if(c1+c2+c3>=MaxTotal)return false;
   if(m==MAGIC_1&&c1>=MaxPerMagic)return false;
   if(m==MAGIC_2&&c2>=MaxPerMagic)return false;
   if(m==MAGIC_3&&c3>=MaxPerMagic)return false;
   return true;
}

int HelperMagic(int vic){ return (vic==MAGIC_1)?MAGIC_3:MAGIC_1; }

// ตรวจว่า Guardian กำลังใช้งาน magic นั้น (victim หรือ helper) อยู่
bool IsGuardInvolved(int m){
   if(!UseGuard||!gG.active)return false;
   int vic=(int)gG.target;
   int hlp=HelperMagic(vic);
   return(m==vic||m==hlp||m==MAGIC_2);
}

bool OO(int m,int d,double lot){
   // ถ้าเป็น victim ที่ถูกหยุด (Phase 1 เท่านั้น) → ห้ามออก
   if(IsVictimStopped(m))return false;
   if(!CanP(m)||!SpreadOK()||!ADXOk(m))return false;
   // FIX #1: Phase 2 (reversed=true) victim ออกได้แล้ว — block เฉพาะ Phase 1 (!reversed)
   // Phase 3 (resumeMode=true) ทุกคนออกได้ตามปกติ
   if(UseGuard&&gG.active&&(int)gG.target==m&&!gG.resumeMode&&!gG.reversed)return false;
   CTrade*tr=TR(m);
   bool ok=(d==1)?tr.Buy(lot,_Symbol,0,0,0,"M"+IntegerToString(m))
                 :tr.Sell(lot,_Symbol,0,0,0,"M"+IntegerToString(m));
   if(!ok)PrintFormat("[OO] FAIL Magic%d err=%d",m,GetLastError());
   return ok;
}

//+------------------------------------------------------------------+
//| BPK                                                              |
//+------------------------------------------------------------------+
void BPKElect(BPKSlot &arr[],int sz,ENUM_POSITION_TYPE pt){
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t))continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol)continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)!=pt)continue;
      long mg=PositionGetInteger(POSITION_MAGIC);
      if(mg!=MAGIC_1&&mg!=MAGIC_2&&mg!=MAGIC_3)continue;
      double pr=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      if(pr<BPKMinP)continue;
      bool dup=false;
      for(int j=0;j<sz;j++)if(arr[j].valid&&arr[j].ticket==t){dup=true;break;}
      if(dup)continue;
      int sl=-1;double w=DBL_MAX;
      for(int j=0;j<sz;j++){if(!arr[j].valid){sl=j;break;}if(arr[j].profit<w){w=arr[j].profit;sl=j;}}
      if(sl<0)continue;
      if(!arr[sl].valid||pr>arr[sl].profit){
         arr[sl].ticket=t;arr[sl].magic=(int)mg;arr[sl].dir=(pt==POSITION_TYPE_BUY)?1:-1;
         arr[sl].profit=pr;arr[sl].valid=true;
      }
   }
}
void UpdBPK(){
   if(!UseBPK)return;
   if(ArraySize(gBB)!=BPKBuy) {ArrayResize(gBB,BPKBuy); for(int i=0;i<BPKBuy; i++)gBB[i].valid=false;}
   if(ArraySize(gBS)!=BPKSell){ArrayResize(gBS,BPKSell);for(int i=0;i<BPKSell;i++)gBS[i].valid=false;}
   for(int i=0;i<ArraySize(gBB);i++){
      if(!gBB[i].valid)continue;
      if(!PositionSelectByTicket(gBB[i].ticket)){gBB[i].valid=false;continue;}
      gBB[i].profit=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      if(gBB[i].profit<BPKMinP)gBB[i].valid=false;
   }
   for(int i=0;i<ArraySize(gBS);i++){
      if(!gBS[i].valid)continue;
      if(!PositionSelectByTicket(gBS[i].ticket)){gBS[i].valid=false;continue;}
      gBS[i].profit=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      if(gBS[i].profit<BPKMinP)gBS[i].valid=false;
   }
   BPKElect(gBB,BPKBuy, POSITION_TYPE_BUY);
   BPKElect(gBS,BPKSell,POSITION_TYPE_SELL);
}
void SetBPKBreakeven(BPKSlot &arr[])
{
   for(int i=0;i<ArraySize(arr);i++){
      if(!arr[i].valid)continue;
      if(!PositionSelectByTicket(arr[i].ticket))continue;
      double op  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl  = PositionGetDouble(POSITION_SL);
      double otp = PositionGetDouble(POSITION_TP);
      int    d   = (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)?1:-1;
      // BPKBEPts points เหนือ open สำหรับ BUY / ต่ำกว่า open สำหรับ SELL
      // ค่า 0 = SL อยู่ที่ราคาเปิดพอดี (หักค่า spread อาจปิดขาดทุนเล็กน้อย)
      double nsl = op + d * BPKBEPts * _Point;
      bool imp=(d==1)?(nsl>sl||sl==0):(nsl<sl||sl==0);
      if(imp){
         CTrade*tr=TR(arr[i].magic);
         if(tr.PositionModify(arr[i].ticket,nsl,otp))
            PrintFormat("[BPK] BE SL set #%I64u op=%.5f nsl=%.5f (+%d pts)",arr[i].ticket,op,nsl,BPKBEPts);
      }
   }
}

void ChkBPK(){
   if(!UseBPK)return;

   double t=0;int v=0;
   for(int i=0;i<ArraySize(gBB);i++)if(gBB[i].valid){t+=gBB[i].profit;v++;}
   gBBTP=t;
   if(v>=BPKBuy && BPKBuy>0) SetBPKBreakeven(gBB);
   if(v>0&&t>=BPKBuyTP){
      PrintFormat("[BPK] BUY TP $%.2f (%d slots)",t,v);
      for(int i=0;i<ArraySize(gBB);i++){
         if(!gBB[i].valid)continue;
         CTrade*tr=TR(gBB[i].magic);
         if(tr.PositionClose(gBB[i].ticket))gBBC++;
         gBB[i].valid=false;
      }
   }

   t=0;v=0;
   for(int i=0;i<ArraySize(gBS);i++)if(gBS[i].valid){t+=gBS[i].profit;v++;}
   gBSTP=t;
   if(v>=BPKSell && BPKSell>0) SetBPKBreakeven(gBS);
   if(v>0&&t>=BPKSellTP){
      PrintFormat("[BPK] SELL TP $%.2f (%d slots)",t,v);
      for(int i=0;i<ArraySize(gBS);i++){
         if(!gBS[i].valid)continue;
         CTrade*tr=TR(gBS[i].magic);
         if(tr.PositionClose(gBS[i].ticket))gBSC++;
         gBS[i].valid=false;
      }
   }
}

//+------------------------------------------------------------------+
//| DD ABSORPTION                                                    |
//+------------------------------------------------------------------+
void ChkDDA(){
   if(!UseDDA)return;
   double dd=DD();if(dd<=0)return;
   if(TimeCurrent()-gLastAbs<DDACool)return;
   int b=0;
   if(dd>=DDA3)b=DDACnt3;else if(dd>=DDA2)b=DDACnt2;else if(dd>=DDA1)b=DDACnt1;
   if(b==0)return;
   double a[];int c=0;
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t)||PositionGetString(POSITION_SYMBOL)!=_Symbol||IsBPK(t))continue;
      double p=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      if(p<0){ArrayResize(a,c+1);a[c++]=p;}
   }
   if(c==0)return;
   for(int i=0;i<c-1;i++)for(int j=i+1;j<c;j++)if(a[j]<a[i]){double x=a[i];a[i]=a[j];a[j]=x;}
   double tot=0;for(int i=0;i<MathMin(b,c);i++)tot+=MathAbs(a[i]);
   if(tot>0){gDG+=tot;gLastAbs=TimeCurrent();PrintFormat("[DDA] DD=%.2f%% +$%.2f G=$%.2f",dd,tot,gDG);}
}

//+------------------------------------------------------------------+
//| TP LOGIC                                                         |
//+------------------------------------------------------------------+
double TPReq(int m){
   double base=(m==MAGIC_1)?TP1:(m==MAGIC_2)?TP2:TP3;
   double debt=(m==MAGIC_1)?gD1:(m==MAGIC_2)?gD2:gD3;
   return base+debt+gDG;
}

void SyncAfterTP(int m){
   if(m==MAGIC_1){
      sM1.cnt=CNB(MAGIC_1);
      if(sM1.dir!=0)sM1.lastPrice=(sM1.dir==1)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
   }else if(m==MAGIC_2){
      sM2.cnt=CNB(MAGIC_2);
      if(sM2.dir!=0)sM2.lastPrice=(sM2.dir==1)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
   }else{
      sM3.cnt=CNB(MAGIC_3);
      if(sM3.dir!=0)sM3.lastPrice=(sM3.dir==1)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
   }
}

//+------------------------------------------------------------------+
//| ReOpen helpers                                                    |
//+------------------------------------------------------------------+
void ScheduleReOpen(int m, int dir)
{
   if(!UseReOpen) return;
   if(ROGuardOnly && !gG.active) return;
   if(dir==0) return;
   datetime t = TimeCurrent() + RODelay;
   if(m==MAGIC_1){gROTime1=t; gRODir1=dir;}
   else if(m==MAGIC_2){gROTime2=t; gRODir2=dir;}
   else            {gROTime3=t; gRODir3=dir;}
   PrintFormat("[RO] schedule M%d %s delay=%ds",m,(dir==1?"BUY":"SELL"),RODelay);
}

void ProcReOpen()
{
   if(!UseReOpen) return;
   datetime now = TimeCurrent();

   if(gROTime1>0 && now>=gROTime1 && gRODir1!=0)
   {
      if(CanP(MAGIC_1) && SpreadOK() && !IsVictimStopped(MAGIC_1))
      {
         int n = CNB(MAGIC_1)+1;
         if(OO(MAGIC_1,gRODir1,Lot(n))){
            sM1.cnt=CNB(MAGIC_1);
            double ep=(gRODir1==1)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
            sM1.lastPrice=ep;
            PrintFormat("[RO] M1 %s opened @%.5f cnt=%d",(gRODir1==1?"BUY":"SELL"),ep,sM1.cnt);
         }
      }
      gROTime1=0; gRODir1=0;
   }

   if(gROTime2>0 && now>=gROTime2 && gRODir2!=0)
   {
      if(CanP(MAGIC_2) && SpreadOK())
      {
         int n = CNB(MAGIC_2)+1;
         if(OO(MAGIC_2,gRODir2,Lot(n))){
            sM2.cnt=CNB(MAGIC_2);
            double ep=(gRODir2==1)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
            sM2.lastPrice=ep;
            if(gRODir2==1) sM2.lastBuyP=ep; else sM2.lastSellP=ep;
            PrintFormat("[RO] M2 %s opened @%.5f cnt=%d",(gRODir2==1?"BUY":"SELL"),ep,sM2.cnt);
         }
      }
      gROTime2=0; gRODir2=0;
   }

   if(gROTime3>0 && now>=gROTime3 && gRODir3!=0)
   {
      if(CanP(MAGIC_3) && SpreadOK() && !IsVictimStopped(MAGIC_3))
      {
         int n = CNB(MAGIC_3)+1;
         if(OO(MAGIC_3,gRODir3,Lot(n))){
            sM3.cnt=CNB(MAGIC_3);
            double ep=(gRODir3==1)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
            sM3.lastPrice=ep;
            PrintFormat("[RO] M3 %s opened @%.5f cnt=%d",(gRODir3==1?"BUY":"SELL"),ep,sM3.cnt);
         }
      }
      gROTime3=0; gRODir3=0;
   }
}

int GetActiveDir(int m)
{
   if(m==MAGIC_1) return sM1.active?sM1.dir:0;
   if(m==MAGIC_2) return sM2.active?sM2.dir:0;
   return sM3.active?sM3.dir:0;
}

//+------------------------------------------------------------------+
//| DoTP                                                             |
//+------------------------------------------------------------------+
void DoTP(int m, double req)
{
   CTrade *tr = TR(m);

   ulong  tkP[]; double pfP[]; int nP=0;
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t))continue;
      if(PositionGetInteger(POSITION_MAGIC)!=m)continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol)continue;
      if(IsBPK(t))continue;
      double p=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      if(p>0){ArrayResize(tkP,nP+1);ArrayResize(pfP,nP+1);tkP[nP]=t;pfP[nP]=p;nP++;}
   }
   if(nP==0){PrintFormat("[TP] M%d ไม่มีไม้กำไร skip",m);return;}
   for(int i=0;i<nP-1;i++)
      for(int j=i+1;j<nP;j++)
         if(pfP[j]>pfP[i]){double x=pfP[i];pfP[i]=pfP[j];pfP[j]=x;ulong u=tkP[i];tkP[i]=tkP[j];tkP[j]=u;}

   ulong  tkL[]; double pfL[]; int nL=0;
   if(SelfAbs>0) nL=GetWorstLoss(m,SelfAbs,tkL,pfL);

   int    bestAk  = -1;
   int    bestNL  =  0;
   double bestCp  =  0;
   double bestLoss=  0;

   int lTryMin = (nL>0 && SelfAbs>0) ? 1 : 0;

   for(int lTry=nL; lTry>=lTryMin; lTry--)
   {
      double tryLoss=0;
      for(int i=0;i<lTry;i++) tryLoss+=MathAbs(pfL[i]);
      double grossNeed = req + tryLoss;

      int    keep = MathMin(SKCount, nP);
      int    ak   = keep;
      double cp   = 0;
      for(int i=keep; i<nP; i++) cp+=pfP[i];
      for(int i=keep-1; i>=0 && cp<grossNeed; i--){cp+=pfP[i]; ak--;}

      if(cp>=grossNeed){
         bestAk=ak; bestNL=lTry; bestCp=cp; bestLoss=tryLoss;
         break;
      }
   }

   if(bestAk<0){
      PrintFormat("[TP] M%d รอ: gross=$%.2f ต้องการ=$%.2f+loss(1ไม้)=$%.2f",
                  m, GrossProfitNB(m), req,
                  nL>0 ? MathAbs(pfL[0]) : 0.0);
      return;
   }

   int closedP=0;
   for(int i=bestAk; i<nP; i++)
      if(tr.PositionClose(tkP[i])) closedP++;

   int closedL=0;
   for(int i=0; i<bestNL; i++){
      if(tr.PositionClose(tkL[i])){
         closedL++;
         PrintFormat("[TP] M%d ดึงไม้เสีย #%I64u P=$%.2f",m,tkL[i],pfL[i]);
      }
   }

   for(int i=0; i<bestAk; i++){
      if(!PositionSelectByTicket(tkP[i]))continue;
      double op  = PositionGetDouble(POSITION_PRICE_OPEN);
      double csl = PositionGetDouble(POSITION_SL);
      double otp = PositionGetDouble(POSITION_TP);
      int    d   = (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)?1:-1;
      double nsl = op + d*(SKBE>0?SKBE:0)*_Point;
      bool   imp = (d==1)?(nsl>csl||csl==0):(nsl<csl||csl==0);
      if(imp) tr.PositionModify(tkP[i],nsl,otp);
   }

   if(m==MAGIC_1)gD1=0; else if(m==MAGIC_2)gD2=0; else gD3=0;
   gDG=MathMax(0, gDG-MathMax(0, req-bestLoss));

   SyncAfterTP(m);
   ScheduleReOpen(m, GetActiveDir(m));
   PrintFormat("[TP] M%d ✓ เก็บ:%d ปิดกำไร:%d($%.2f) ดึงเสีย:%d/$%.2f net=$%.2f | D=%.2f/%.2f/%.2f G=%.2f",
               m,bestAk,closedP,bestCp,closedL,bestLoss,bestCp-bestLoss,gD1,gD2,gD3,gDG);
}

bool CanDoTP(int m, double req){
   double gp = GrossProfitNB(m);
   if(SelfAbs<=0) return gp>=req;
   ulong tk1[]; double pf1[];
   int n1=GetWorstLoss(m,1,tk1,pf1);
   double minLoss = (n1>0) ? MathAbs(pf1[0]) : 0.0;
   return gp >= req + minLoss;
}

// FIX #3 & #4: ข้าม M1/M3 เมื่อ Guardian กำลังใช้งาน magic นั้นอยู่
//              ข้าม M2 เมื่อ Guardian active (Guardian ควบคุม M2 เอง)
void ChkSepTP(){
   if(!UseSepTP)return;
   bool gInv1 = IsGuardInvolved(MAGIC_1);
   bool gInv3 = IsGuardInvolved(MAGIC_3);
   if(En1&&sM1.active&&!gInv1){double r=TPReq(MAGIC_1);if(CanDoTP(MAGIC_1,r))DoTP(MAGIC_1,r);}
   if(En2&&sM2.active&&!gG.active){double r=TPReq(MAGIC_2);if(CanDoTP(MAGIC_2,r))DoTP(MAGIC_2,r);}
   if(En3&&sM3.active&&!gInv3){double r=TPReq(MAGIC_3);if(CanDoTP(MAGIC_3,r))DoTP(MAGIC_3,r);}
}

// FIX #3 & #4: ข้าม M1/M2/M3 ที่ Guardian ใช้งานอยู่
void ChkTotTP(){
   if(!UseTotTP)return;
   double g1=En1?GrossProfitNB(MAGIC_1):0,g2=En2?GrossProfitNB(MAGIC_2):0,g3=En3?GrossProfitNB(MAGIC_3):0;
   double req=TPAll+gD1+gD2+gD3+gDG;
   if(g1+g2+g3<req)return;
   bool gInv1=IsGuardInvolved(MAGIC_1);
   bool gInv3=IsGuardInvolved(MAGIC_3);
   if(En1&&sM1.active&&!gInv1&&CanDoTP(MAGIC_1,TPReq(MAGIC_1)))DoTP(MAGIC_1,TPReq(MAGIC_1));
   if(En2&&sM2.active&&!gG.active&&CanDoTP(MAGIC_2,TPReq(MAGIC_2)))DoTP(MAGIC_2,TPReq(MAGIC_2));
   if(En3&&sM3.active&&!gInv3&&CanDoTP(MAGIC_3,TPReq(MAGIC_3)))DoTP(MAGIC_3,TPReq(MAGIC_3));
}

void ChkTwoTP(){
   if(!UseTwoTP)return;
   // FIX #3: ข้าม pair ที่ Guardian ใช้งานอยู่
   if(En1&&En2&&!gG.active){
      double r=TPTwo+gD1+gD2+gDG;
      if(GrossProfitNB(MAGIC_1)+GrossProfitNB(MAGIC_2)>=r){
         if(CanDoTP(MAGIC_1,TPReq(MAGIC_1)))DoTP(MAGIC_1,TPReq(MAGIC_1));
         if(CanDoTP(MAGIC_2,TPReq(MAGIC_2)))DoTP(MAGIC_2,TPReq(MAGIC_2));
      }
   }
   if(En1&&En3&&!gG.active){
      double r=TPTwo+gD1+gD3+gDG;
      if(GrossProfitNB(MAGIC_1)+GrossProfitNB(MAGIC_3)>=r){
         if(CanDoTP(MAGIC_1,TPReq(MAGIC_1)))DoTP(MAGIC_1,TPReq(MAGIC_1));
         if(CanDoTP(MAGIC_3,TPReq(MAGIC_3)))DoTP(MAGIC_3,TPReq(MAGIC_3));
      }
   }
   if(En2&&En3&&!gG.active){
      double r=TPTwo+gD2+gD3+gDG;
      if(GrossProfitNB(MAGIC_2)+GrossProfitNB(MAGIC_3)>=r){
         if(CanDoTP(MAGIC_2,TPReq(MAGIC_2)))DoTP(MAGIC_2,TPReq(MAGIC_2));
         if(CanDoTP(MAGIC_3,TPReq(MAGIC_3)))DoTP(MAGIC_3,TPReq(MAGIC_3));
      }
   }
}

//+------------------------------------------------------------------+
//| GUARDIAN SYSTEM                                                  |
//+------------------------------------------------------------------+

int OpenGBurst(int dir, int cnt, string tag)
{
   if(cnt<=0)return 0;
   int opened=0;
   for(int i=0;i<cnt;i++){
      if(!CanP(MAGIC_2)||!SpreadOK())break;
      int    n  =gG.cnt+1;
      double lot=Lot(n);
      bool ok=(dir==1)?T2.Buy(lot,_Symbol,0,0,0,tag):T2.Sell(lot,_Symbol,0,0,0,tag);
      if(ok){gG.cnt++;sM2.cnt=gG.cnt;gG.lastOrderT=TimeCurrent();opened++;
             PrintFormat("[G] Burst+%d %s lot=%.2f",opened,(dir==1?"B":"S"),lot);}
      else{PrintFormat("[G] BurstFail %d err=%d",i+1,GetLastError());break;}
   }
   gG.lastPrice=(dir==1)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
   sM2.lastPrice=gG.lastPrice;
   return opened;
}

void RG(){
   if(gG.active)PrintFormat("[G] OFF abs=%d",gG.totalAbs);
   gG.active=false;gG.target=GT_NONE;gG.dir=0;gG.lastPrice=0;gG.cnt=0;
   gG.startT=0;gG.lastOrderT=0;gG.trigPrice=0;
   gG.victimStopped=false;gG.reversed=false;gG.resumeMode=false;gG.resumePrice=0;
   RR(sM2);
}

void SetHelperDir(int hlp, int dir){
   double ep=(dir==1)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(hlp==MAGIC_1) SR(sM1,true,dir,ep,TimeCurrent());
   else             SR(sM3,true,dir,ep,TimeCurrent());
}

void StopHelper(int hlp){
   if(hlp==MAGIC_1){sM1.active=false; sM1.dir=0;}
   else            {sM3.active=false; sM3.dir=0;}
}

void ActGuard(int vic)
{
   if(!UseGuard||!En2)return;

   int vdir=(vic==MAGIC_1)?sM1.dir:sM3.dir;
   if(vdir==0){Print("[G] victim dir=0");return;}

   int cdir=-vdir;
   int hlp=HelperMagic(vic);
   bool hEn=(hlp==MAGIC_1)?En1:En3;

   if(sM2.active)CM(MAGIC_2);
   RR(sM2);

   double trigP=(cdir==1)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);

   gG.active        = true;
   gG.target        = (ENUM_GTARGET)vic;
   gG.dir           = cdir;
   gG.trigPrice     = trigP;
   gG.lastPrice     = trigP;
   gG.cnt           = 0;
   gG.startT        = TimeCurrent();
   gG.lastOrderT    = 0;
   gG.victimStopped = true;
   gG.reversed      = false;
   gG.resumeMode    = false;
   gG.resumePrice   = 0;
   gG.totalAbs      = 0;

   if(hEn) SetHelperDir(hlp, cdir);

   SR(sM2,true,cdir,trigP,TimeCurrent());
   int b=OpenGBurst(cdir,GInitCnt,"G");
   if(b==0){Print("[G] Burst fail abort");RG();return;}

   PrintFormat("[G] P1 START vic=M%d(%s) counter=%s trigP=%.5f",
               vic,(vdir==1?"BUY":"SELL"),(cdir==1?"BUY":"SELL"),trigP);
}

void ChkGGrid()
{
   if(!gG.active||gG.reversed||gG.resumeMode)return;
   if(!SpreadOK())return;
   if(TimeCurrent()-gG.lastOrderT<GCool)return;
   int sp=(GStep>0)?GStep:gs2; double spP=sp*_Point; if(spP<=0)return;
   double cur=(gG.dir==1)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double diff=(gG.dir==1)?(gG.lastPrice-cur):(cur-gG.lastPrice);
   if(diff<spP-_Point*0.1)return;
   int n=gG.cnt+1; double lot=Lot(n);
   bool ok=(gG.dir==1)?T2.Buy(lot,_Symbol,0,0,0,"G+"):T2.Sell(lot,_Symbol,0,0,0,"G+");
   if(ok){gG.cnt++;sM2.cnt=gG.cnt;gG.lastPrice=cur;sM2.lastPrice=cur;
          gG.lastOrderT=TimeCurrent();PrintFormat("[G] P1 Grid+%d",n);}
}

// FIX #2: เปลี่ยนจาก GrossProfitNB เป็น PNLNB เพื่อให้ trigger ตรงกับ net จริงที่ได้หลัง CM()
void ChkGTP()
{
   if(!gG.active||gG.reversed||gG.resumeMode)return;
   int vic=(int)gG.target;
   int hlp=HelperMagic(vic);
   bool hEn=(hlp==MAGIC_1)?En1:En3;

   // ใช้ net PNL (รวมทั้งกำไร+ขาดทุน) เพื่อให้สอดคล้องกับ CM() ที่ปิดทุกไม้
   double pM2 = PNLNB(MAGIC_2);
   double pH  = hEn ? PNLNB(hlp) : 0;
   double comb = pM2 + pH;
   double absLoss=WLoss(vic,GAbsCnt);
   double need=absLoss+GNetTP;
   if(need<=0||comb<need)return;

   PrintFormat("[G] P1 TP comb=$%.2f need=$%.2f",comb,need);

   int cl=CW(vic,GAbsCnt);
   gG.totalAbs+=cl;
   if(vic==MAGIC_1)gD1=MathMax(0,gD1-absLoss); else gD3=MathMax(0,gD3-absLoss);
   gDG=MathMax(0,gDG-absLoss);

   CM(MAGIC_2);
   if(hEn)CM(hlp);

   double pVic=PNLNB(vic);
   double thr=(vic==MAGIC_1)?GTrig1:GTrig3;
   if(pVic<=-thr){
      PrintFormat("[G] P1 victim M%d $%.2f → loop",vic,pVic);
      gG.cnt=0; gG.lastOrderT=0;
      double ep=(gG.dir==1)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
      SR(sM2,true,gG.dir,ep,TimeCurrent());
      gG.lastPrice=ep;
      if(hEn) SetHelperDir(hlp,gG.dir);
      OpenGBurst(gG.dir,GInitCnt,"G");
   } else {
      PrintFormat("[G] P1 victim M%d ฟื้น → OFF",vic);
      RG();
      if(CP(MAGIC_1)==0)RR(sM1);
      if(CP(MAGIC_3)==0)RR(sM3);
   }
}

// FIX #1: เพิ่ม gG.victimStopped = false เพื่อให้ victim ออกออเดอร์ใน Phase 2 ได้
void ChkGReverse()
{
   if(!gG.active||gG.reversed||gG.resumeMode)return;
   double cur=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   bool crossed=false;
   if(gG.dir==1  && cur<=gG.trigPrice+_Point*0.5) crossed=true;
   if(gG.dir==-1 && cur>=gG.trigPrice-_Point*0.5) crossed=true;
   if(!crossed)return;

   PrintFormat("[G] P2 START: กราฟผ่าน trigP=%.5f cur=%.5f",gG.trigPrice,cur);
   gG.reversed=true;

   int vic=(int)gG.target;
   int hlp=HelperMagic(vic);
   bool hEn=(hlp==MAGIC_1)?En1:En3;
   bool vEn=(vic==MAGIC_1)?En1:En3;

   int p2dir = -gG.dir;

   // หยุดออกออเดอร์ใหม่ M2 เดิม (ไม่ปิดไม้เก่า)
   RR(sM2);

   // helper หยุดออกออเดอร์ใหม่ (ไม้เก่าค้างอยู่)
   StopHelper(hlp);

   // FIX #1: เปิด victimStopped = false เพื่อให้ victim ออก p2dir ได้ใน Phase 2
   gG.victimStopped = false;

   // victim เดิม: กลับมาออกออเดอร์ฝั่ง p2dir ได้
   if(vEn) SetHelperDir(vic, p2dir);

   gG.resumePrice = gG.trigPrice + (double)p2dir * GResumeOfs * _Point;
   gG.dir         = p2dir;

   double ep=(p2dir==1)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
   SR(sM2,true,p2dir,ep,TimeCurrent());
   gG.cnt=0; gG.lastOrderT=0; gG.lastPrice=ep;
   int b2=OpenGBurst(p2dir,GInitCnt,"Gs");
   if(b2==0){Print("[G] P2 Burst fail");}

   PrintFormat("[G] P2: M%d止(ไม้ค้าง) M%d+M2→%s resumeP=%.5f",
               hlp,vic,(p2dir==1?"BUY":"SELL"),gG.resumePrice);
}

void ChkGSwitchGrid()
{
   if(!gG.active||!gG.reversed||gG.resumeMode)return;
   if(!SpreadOK())return;
   if(TimeCurrent()-gG.lastOrderT<GCool)return;
   int sp=(GStep>0)?GStep:gs2; double spP=sp*_Point; if(spP<=0)return;
   double cur=(gG.dir==1)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double diff=(gG.dir==1)?(cur-gG.lastPrice):(gG.lastPrice-cur);
   if(diff<spP-_Point*0.1)return;
   int n=gG.cnt+1; double lot=Lot(n);
   bool ok=(gG.dir==1)?T2.Buy(lot,_Symbol,0,0,0,"Gs+"):T2.Sell(lot,_Symbol,0,0,0,"Gs+");
   if(ok){gG.cnt++;sM2.cnt=gG.cnt;gG.lastPrice=cur;sM2.lastPrice=cur;
          gG.lastOrderT=TimeCurrent();PrintFormat("[G] P2 Grid+%d",n);}
}

// FIX #2: เปลี่ยนจาก GrossProfitNB เป็น PNLNB เพื่อให้ trigger ตรงกับ net จริง
void ChkGSwitchTP()
{
   if(!gG.active||!gG.reversed||gG.resumeMode)return;

   int vic=(int)gG.target;
   int hlp=HelperMagic(vic);
   bool vEn=(vic==MAGIC_1)?En1:En3;

   // ใช้ net PNL (รวมทั้งกำไร+ขาดทุน)
   double gM2  = PNLNB(MAGIC_2);
   double gVic = vEn ? PNLNB(vic) : 0;
   double comb = gM2 + gVic;

   double absLoss=WLoss(hlp,GAbsCnt);
   double need=absLoss+GNetTP;
   if(need<=0||comb<need)return;

   PrintFormat("[G] P2 TP comb=$%.2f need=$%.2f absM_hlp=$%.2f",comb,need,absLoss);

   int cl=CW(hlp,GAbsCnt);
   gG.totalAbs+=cl;
   if(hlp==MAGIC_1)gD1=MathMax(0,gD1-absLoss); else gD3=MathMax(0,gD3-absLoss);
   gDG=MathMax(0,gDG-absLoss);

   // ปิดเฉพาะไม้กำไรของ M2 (ไม่ปิดทั้งหมด)
   CTrade *tr=TR(MAGIC_2);
   int closedM2=0;
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t))continue;
      if(PositionGetInteger(POSITION_MAGIC)!=MAGIC_2)continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol)continue;
      double p=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      if(p>0){if(tr.PositionClose(t))closedM2++;}
   }

   double ep=(gG.dir==1)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
   SR(sM2,true,gG.dir,ep,TimeCurrent());
   gG.cnt=0; gG.lastOrderT=0; gG.lastPrice=ep;
   OpenGBurst(gG.dir,GInitCnt,"Gs");

   PrintFormat("[G] P2 TP ✓ ดึงHlp:%d ปิดM2กำไร:%d → loop ต่อ",cl,closedM2);
}

void ChkGResume()
{
   if(!gG.active||!gG.reversed||gG.resumeMode)return;
   double cur=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   bool reached=false;
   if(gG.dir==1  && cur>=gG.resumePrice-_Point*0.5) reached=true;
   if(gG.dir==-1 && cur<=gG.resumePrice+_Point*0.5) reached=true;
   if(!reached)return;

   gG.resumeMode    = true;
   gG.victimStopped = false;

   int vic=(int)gG.target;
   int hlp=HelperMagic(vic);
   bool hEn=(hlp==MAGIC_1)?En1:En3;
   if(hEn) SetHelperDir(hlp, gG.dir);

   PrintFormat("[G] P3 RESUME: M%d(helper)กลับมา cur=%.5f",hlp,cur);
}

// FIX #2: เปลี่ยนจาก GrossProfitNB เป็น PNLNB
void ChkGResumeTP()
{
   if(!gG.active||!gG.resumeMode)return;
   int vic=(int)gG.target;
   int hlp=HelperMagic(vic);

   // ใช้ net PNL (รวมทั้งกำไร+ขาดทุน)
   double pM2  = PNLNB(MAGIC_2);
   double pVic = PNLNB(vic);
   double pHlp = PNLNB(hlp);
   double comb = pM2 + pVic + pHlp;

   double absV=WLoss(vic,GAbsCnt);
   double absH=WLoss(hlp,GAbsCnt);
   double need=(absV+absH)+GNetTP;
   if(need<=0||comb<need)return;

   PrintFormat("[G] P3 TP comb=$%.2f need=$%.2f",comb,need);

   int clV=CW(vic,GAbsCnt); gG.totalAbs+=clV;
   int clH=CW(hlp,GAbsCnt); gG.totalAbs+=clH;
   if(vic==MAGIC_1)gD1=MathMax(0,gD1-absV); else gD3=MathMax(0,gD3-absV);
   if(hlp==MAGIC_1)gD1=MathMax(0,gD1-absH); else gD3=MathMax(0,gD3-absH);
   gDG=MathMax(0,gDG-(absV+absH));
   CM(MAGIC_2);

   ScheduleReOpen(vic, gG.dir);
   ScheduleReOpen(hlp, gG.dir);
   ScheduleReOpen(MAGIC_2, gG.dir);

   RG();
   if(CP(MAGIC_1)==0)RR(sM1);
   if(CP(MAGIC_3)==0)RR(sM3);
   PrintFormat("[G] P3 ✓ clV=%d clH=%d",clV,clH);
}

void ProcGuard()
{
   if(!UseGuard||!En2)return;

   if(gG.active){
      if(!gG.reversed&&!gG.resumeMode){
         ChkGReverse();
         ChkGGrid();
         ChkGTP();
      } else if(gG.reversed&&!gG.resumeMode){
         ChkGResume();
         ChkGSwitchGrid();
         ChkGSwitchTP();
      } else {
         ChkGResumeTP();
      }
      return;
   }

   double p1=En1?PNLNB(MAGIC_1):0, p3=En3?PNLNB(MAGIC_3):0;
   if(En1&&sM1.active&&p1<=-GTrig1)     ActGuard(MAGIC_1);
   else if(En3&&sM3.active&&p3<=-GTrig3) ActGuard(MAGIC_3);
}


//+------------------------------------------------------------------+
//| SIGNALS & GRID                                                   |
//+------------------------------------------------------------------+
bool DetEng(ENUM_TIMEFRAMES tf,int &dir,datetime &bt){
   MqlRates r[];ArraySetAsSeries(r,true);
   if(CopyRates(_Symbol,tf,0,3,r)!=3)return false;
   bool g=(r[1].close>r[1].open)&&(r[1].close>r[2].close)&&(r[1].open<r[2].open);
   bool rd=(r[1].close<r[1].open)&&(r[1].close<r[2].close)&&(r[1].open>r[2].open);
   if(!g&&!rd)return false;dir=g?1:-1;bt=r[1].time;return true;
}
void StartM1(int d,datetime t){
   if(!En1||sM1.active)return;
   double p=(d==1)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
   SR(sM1,true,d,p,t);
   if(OO(MAGIC_1,d,Lot(1)))sM1.cnt=1;else RR(sM1);
}
void StartM2(int d,datetime t){
   if(!En2||sM2.active||gG.active)return;
   if(M2Mode==M2_ONEWAY){
      int dd=-d;double p=(dd==1)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
      SR(sM2,true,dd,p,t);
      if(OO(MAGIC_2,dd,Lot(1)))sM2.cnt=1;else RR(sM2);
   }else{
      double mid=(SymbolInfoDouble(_Symbol,SYMBOL_BID)+SymbolInfoDouble(_Symbol,SYMBOL_ASK))/2.0;
      SR(sM2,true,0,mid,t);
   }
}
void StartM3(int d,datetime t){
   if(!En3||sM3.active)return;
   int d3=(LinkM1M3&&En1&&sM1.active)?-sM1.dir:-d;
   double p=(d3==1)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
   SR(sM3,true,d3,p,t);
   if(OO(MAGIC_3,d3,Lot(1)))sM3.cnt=1;else RR(sM3);
}
void ProcSig(){
   if(UseMTF){
      int d;datetime bt;
      if(DetEng(TF1,d,bt)&&bt!=gBarM1){gBarM1=bt;StartM1(d,bt);StartM3(d,bt);}
      if(DetEng(TF2,d,bt)&&bt!=gBarM2){gBarM2=bt;StartM2(d,bt);}
   }else{
      int d;datetime bt;
      if(DetEng(_Period,d,bt)&&bt!=gBar){gBar=bt;StartM1(d,bt);StartM2(d,bt);StartM3(d,bt);}
   }
}
void ChkG1(){
   if(!En1||!sM1.active)return;
   double step=gs1*_Point,tol=_Point*0.1;
   double cur=(sM1.dir==1)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double dist=(GridMode13==M13_ONEWAY)?((sM1.dir==1)?(sM1.lastPrice-cur):(cur-sM1.lastPrice)):MathAbs(cur-sM1.lastPrice);
   if(dist<step-tol)return;
   int n=sM1.cnt+1;
   if(OO(MAGIC_1,sM1.dir,Lot(n))){sM1.cnt=n;sM1.lastPrice=cur;}
}
void ChkG2(){
   if(gG.active)return;
   if(!En2||!sM2.active)return;
   double step=gs2*_Point,tol=_Point*0.1;
   if(M2Mode==M2_ONEWAY){
      double cur=(sM2.dir==1)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
      double diff=(sM2.dir==1)?(sM2.lastPrice-cur):(cur-sM2.lastPrice);
      if(diff<step-tol)return;
      int n=sM2.cnt+1;
      if(OO(MAGIC_2,sM2.dir,Lot(n))){sM2.cnt=n;sM2.lastPrice=cur;}
   }else{
      double mid=(SymbolInfoDouble(_Symbol,SYMBOL_BID)+SymbolInfoDouble(_Symbol,SYMBOL_ASK))/2.0;
      if(mid<=sM2.lastBuyP-step+tol){int n=sM2.cnt+1;if(OO(MAGIC_2,1,Lot(n))){sM2.cnt=n;sM2.lastBuyP=mid;}}
      else if(mid>=sM2.lastSellP+step-tol){int n=sM2.cnt+1;if(OO(MAGIC_2,-1,Lot(n))){sM2.cnt=n;sM2.lastSellP=mid;}}
   }
}
void ChkG3(){
   if(!En3||!sM3.active)return;
   double step=gs3*_Point,tol=_Point*0.1;
   double cur=(sM3.dir==1)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double dist=(GridMode13==M13_ONEWAY)?((sM3.dir==1)?(sM3.lastPrice-cur):(cur-sM3.lastPrice)):MathAbs(cur-sM3.lastPrice);
   if(dist<step-tol)return;
   int n=sM3.cnt+1;
   if(OO(MAGIC_3,sM3.dir,Lot(n))){sM3.cnt=n;sM3.lastPrice=cur;}
}
void ChkReset(){
   if(En1&&sM1.active&&CP(MAGIC_1)==0){Print("[R] M1");RR(sM1);}
   if(En2&&sM2.active&&CP(MAGIC_2)==0){if(gG.active){Print("[R] G off");RG();}else RR(sM2);}
   if(En3&&sM3.active&&CP(MAGIC_3)==0){Print("[R] M3");RR(sM3);}
}

//+------------------------------------------------------------------+
//| DAILY VOLUME TRACKING                                            |
//+------------------------------------------------------------------+
double gDailyLotM1=0,gDailyLotM2=0,gDailyLotM3=0;
int    gDailyOrdersM1=0,gDailyOrdersM2=0,gDailyOrdersM3=0;
datetime gLastDayReset=0;

void UpdateDailyStats()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   dt.hour=0;dt.min=0;dt.sec=0;
   datetime dayStart=StructToTime(dt);
   if(gLastDayReset!=dayStart)
   {
      gDailyLotM1=gDailyLotM2=gDailyLotM3=0;
      gDailyOrdersM1=gDailyOrdersM2=gDailyOrdersM3=0;
      gLastDayReset=dayStart;
   }
   if(!HistorySelect(dayStart,TimeCurrent()))return;
   gDailyLotM1=0;gDailyLotM2=0;gDailyLotM3=0;
   gDailyOrdersM1=0;gDailyOrdersM2=0;gDailyOrdersM3=0;
   int total=HistoryDealsTotal();
   for(int i=0;i<total;i++)
   {
      ulong ticket=HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket,DEAL_ENTRY)!=DEAL_ENTRY_IN)continue;
      if(HistoryDealGetString(ticket,DEAL_SYMBOL)!=_Symbol)continue;
      long mg=HistoryDealGetInteger(ticket,DEAL_MAGIC);
      double vol=HistoryDealGetDouble(ticket,DEAL_VOLUME);
      if(mg==MAGIC_1){gDailyLotM1+=vol;gDailyOrdersM1++;}
      else if(mg==MAGIC_2){gDailyLotM2+=vol;gDailyOrdersM2++;}
      else if(mg==MAGIC_3){gDailyLotM3+=vol;gDailyOrdersM3++;}
   }
}

//+------------------------------------------------------------------+
//| DASHBOARD                                                        |
//+------------------------------------------------------------------+
#define DBX   10
#define DBY   10
#define DBW   680
#define DBH   380

#define C_BG      C'18,20,26'
#define C_HDR     C'24,27,36'
#define C_PANEL   C'28,32,42'
#define C_LINE    C'42,48,62'
#define C_ACCENT  C'68,130,210'
#define C_CYAN    C'80,200,240'
#define C_GREEN   C'52,199,120'
#define C_RED     C'232,72,72'
#define C_AMBER   C'240,175,40'
#define C_DIM     C'90,100,125'
#define C_LABEL   C'140,155,185'
#define C_WHITE   C'220,225,235'
#define C_GUARD   C'240,160,40'
#define C_GUARD_BG C'38,32,18'

void _DR(string n,int x,int y,int w,int h,color bg,color bo=clrNONE)
{
   ObjectCreate(0,n,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_XSIZE,w);ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg);ObjectSetInteger(0,n,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0,n,OBJPROP_COLOR,(bo==clrNONE)?bg:bo);ObjectSetInteger(0,n,OBJPROP_WIDTH,1);
   ObjectSetInteger(0,n,OBJPROP_BACK,false);ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
}
void _DL(string n,string txt,int x,int y,int sz,color c,string font="Arial Bold")
{
   ObjectCreate(0,n,OBJ_LABEL,0,0,0);
   ObjectSetString(0,n,OBJPROP_TEXT,txt);ObjectSetString(0,n,OBJPROP_FONT,font);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_COLOR,c);ObjectSetInteger(0,n,OBJPROP_FONTSIZE,sz);
   ObjectSetInteger(0,n,OBJPROP_BACK,false);ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
}
void _DS(string n,string txt,color c=clrNONE)
{
   ObjectSetString(0,n,OBJPROP_TEXT,txt);
   if(c!=clrNONE)ObjectSetInteger(0,n,OBJPROP_COLOR,c);
}

void InitDB()
{
   if(MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE))return;
   ObjectsDeleteAll(0,"HP_");
   int X=DBX,Y=DBY;
   _DR("HP_BG",   X,Y,        DBW,DBH,   C_BG,   C_LINE);
   _DR("HP_HDR",  X,Y,        DBW,32,    C_HDR,  C_ACCENT);
   _DR("HP_SB",   X,Y+32,     DBW,22,    C_PANEL,C_LINE);
   for(int i=0;i<4;i++)_DR("HP_AC"+IntegerToString(i),X+i*170,Y+66,168,62,C_PANEL,C_LINE);
   _DR("HP_MT",   X,Y+134,    DBW,88,    C_PANEL,C_LINE);
   _DR("HP_MR1",  X+1,Y+150,  DBW-2,21,  C'30,34,45',clrNONE);
   _DR("HP_MR3",  X+1,Y+194,  DBW-2,21,  C'30,34,45',clrNONE);
   _DR("HP_DDp",  X,Y+222,    332,72,    C_PANEL,C_LINE);
   _DR("HP_DBp",  X+338,Y+222,342,72,    C_PANEL,C_LINE);
   _DR("HP_BKp",  X,Y+300,    332,52,    C_PANEL,C_LINE);
   _DR("HP_GDp",  X+338,Y+300,342,52,    C_PANEL,C_LINE);
   _DR("HP_FT",   X,Y+358,    DBW,22,    C_HDR,  C_LINE);
   _DR("HP_DV1",  X,Y+64,     DBW,1,     C_LINE);
   _DR("HP_DV2",  X,Y+132,    DBW,1,     C_LINE);
   _DR("HP_DV3",  X,Y+220,    DBW,1,     C_LINE);
   _DR("HP_DV4",  X,Y+298,    DBW,1,     C_LINE);
   _DR("HP_DV5",  X,Y+356,    DBW,1,     C_LINE);

   _DL("HP_LOGO", "HYBRID PRO",          X+12, Y+8,  13,C_CYAN);
   _DL("HP_VER",  "v"+EA_VER,            X+118,Y+10,  8,C_DIM,  "Arial");
   _DL("HP_SYM",  _Symbol,               X+158,Y+8,  12,C_WHITE);
   _DL("HP_TF",   EnumToString(_Period), X+230,Y+10,  8,C_DIM,  "Arial");
   _DL("HP_LIVEDT","● LIVE",             X+530,Y+9,   9,C_GREEN);
   _DL("HP_EXPDT","EXP:"+EXPIRY_STR,     X+590,Y+10,  7,C_DIM,  "Arial");

   _DL("HP_SP",   "SPR:---",             X+12, Y+37,  8,C_LABEL,"Arial");
   _DL("HP_AT",   "ATR:---",             X+100,Y+37,  8,C_LABEL,"Arial");
   _DL("HP_TM",   "--:--:--",            X+200,Y+37,  8,C_LABEL,"Arial");
   _DL("HP_EQ",   "EQ:---",              X+310,Y+37,  8,C_LABEL,"Arial");
   _DL("HP_BAL",  "BAL:---",             X+430,Y+37,  8,C_LABEL,"Arial");
   _DL("HP_FLOAT","FLOAT:---",           X+540,Y+37,  8,C_LABEL,"Arial");

   _DL("HP_A0L",  "P&L รวม",            X+14, Y+72,   8,C_DIM,"Arial");
   _DL("HP_A0V",  "---",                 X+14, Y+87,  14,C_GREEN);
   _DL("HP_A0S",  "วันนี้: ---",        X+14, Y+108,  7,C_DIM,"Arial");
   _DL("HP_A1L",  "Equity",             X+184,Y+72,   8,C_DIM,"Arial");
   _DL("HP_A1V",  "---",                 X+184,Y+87,  14,C_WHITE);
   _DL("HP_A1S",  "Balance: ---",        X+184,Y+108,  7,C_DIM,"Arial");
   _DL("HP_A2L",  "Drawdown",           X+354,Y+72,   8,C_DIM,"Arial");
   _DL("HP_A2V",  "---",                 X+354,Y+87,  14,C_WHITE);
   _DL("HP_A2S",  "Max DD: ---",         X+354,Y+108,  7,C_DIM,"Arial");
   _DL("HP_A3L",  "Lot วันนี้",         X+524,Y+72,   8,C_DIM,"Arial");
   _DL("HP_A3V",  "---",                 X+524,Y+87,  14,C_AMBER);
   _DL("HP_A3S",  "Orders: ---",         X+524,Y+108,  7,C_DIM,"Arial");

   _DL("HP_MHL",  "Magic",   X+14, Y+138,7,C_DIM,"Arial");
   _DL("HP_MHP",  "P&L",     X+100,Y+138,7,C_DIM,"Arial");
   _DL("HP_MHO",  "Pos",     X+200,Y+138,7,C_DIM,"Arial");
   _DL("HP_MHTP", "TP req",  X+270,Y+138,7,C_DIM,"Arial");
   _DL("HP_MHG",  "Grid",    X+380,Y+138,7,C_DIM,"Arial");
   _DL("HP_MHD",  "Dir",     X+440,Y+138,7,C_DIM,"Arial");
   _DL("HP_MHR",  "Round",   X+510,Y+138,7,C_DIM,"Arial");
   _DL("HP_MHS",  "Lot/day", X+590,Y+138,7,C_DIM,"Arial");

   _DL("HP_1L",  "M1",X+14, Y+157,9,C'100,170,255');_DL("HP_1P","---",X+100,Y+157,9,C_WHITE);
   _DL("HP_1O",  "--", X+200,Y+157,8,C_LABEL,"Arial");_DL("HP_1T","---",X+270,Y+157,8,C_LABEL,"Arial");
   _DL("HP_1G",  "--", X+380,Y+157,8,C_LABEL,"Arial");_DL("HP_1D","---",X+440,Y+157,8,C_LABEL,"Arial");
   _DL("HP_1R",  "---",X+510,Y+157,8,C_LABEL,"Arial");_DL("HP_1S","---",X+590,Y+157,8,C_LABEL,"Arial");

   _DL("HP_2L",  "M2",X+14, Y+179,9,C'180,130,255');_DL("HP_2P","---",X+100,Y+179,9,C_WHITE);
   _DL("HP_2O",  "--", X+200,Y+179,8,C_LABEL,"Arial");_DL("HP_2T","---",X+270,Y+179,8,C_LABEL,"Arial");
   _DL("HP_2G",  "--", X+380,Y+179,8,C_LABEL,"Arial");_DL("HP_2D","---",X+440,Y+179,8,C_LABEL,"Arial");
   _DL("HP_2R",  "---",X+510,Y+179,8,C_LABEL,"Arial");_DL("HP_2S","---",X+590,Y+179,8,C_LABEL,"Arial");

   _DL("HP_3L",  "M3",X+14, Y+201,9,C'80,210,170');_DL("HP_3P","---",X+100,Y+201,9,C_WHITE);
   _DL("HP_3O",  "--", X+200,Y+201,8,C_LABEL,"Arial");_DL("HP_3T","---",X+270,Y+201,8,C_LABEL,"Arial");
   _DL("HP_3G",  "--", X+380,Y+201,8,C_LABEL,"Arial");_DL("HP_3D","---",X+440,Y+201,8,C_LABEL,"Arial");
   _DL("HP_3R",  "---",X+510,Y+201,8,C_LABEL,"Arial");_DL("HP_3S","---",X+590,Y+201,8,C_LABEL,"Arial");

   int DX=X+8,DY=Y+226;
   _DL("HP_DDL",  "Drawdown",  DX,   DY,   8,C_DIM,"Arial");
   _DL("HP_DDV",  "---",       DX+80,DY,   9,C_WHITE);
   _DL("HP_DDBL", "── cur",    DX,   DY+14,7,C_DIM,"Arial");
   _DR("HP_DDT",  DX,DY+26,316,6,C_LINE);_DR("HP_DDF",DX,DY+26,1,6,C_GREEN);
   _DL("HP_DDMAX","Max:",      DX,   DY+40,7,C_DIM,"Arial");
   _DL("HP_DDMV", "---",       DX+28,DY+40,7,C_AMBER,"Arial");
   _DL("HP_DDPK", "Peak:",     DX+100,DY+40,7,C_DIM,"Arial");
   _DL("HP_DDPV", "---",       DX+130,DY+40,7,C_LABEL,"Arial");
   _DR("HP_DDMT", DX,DY+52,316,4,C_LINE);_DR("HP_DDMF",DX,DY+52,1,4,C_AMBER);

   int BX=X+346,BY=Y+226;
   _DL("HP_DBL",  "Debt ledger",BX,   BY,   8,C_DIM,"Arial");
   _DL("HP_DB1L", "M1:",        BX,   BY+15,7,C_DIM,"Arial");_DL("HP_DB1V","$0.00",BX+24, BY+15,8,C_GREEN,"Arial");
   _DL("HP_DB2L", "M2:",        BX+90,BY+15,7,C_DIM,"Arial");_DL("HP_DB2V","$0.00",BX+114,BY+15,8,C_GREEN,"Arial");
   _DL("HP_DB3L", "M3:",        BX+180,BY+15,7,C_DIM,"Arial");_DL("HP_DB3V","$0.00",BX+204,BY+15,8,C_GREEN,"Arial");
   _DL("HP_DBGL", "Global:",    BX,   BY+32,7,C_DIM,"Arial");_DL("HP_DBGV","$0.00",BX+42,BY+32,9,C_GREEN);
   _DL("HP_DBTPL","TP adj:",    BX+190,BY+32,7,C_DIM,"Arial");_DL("HP_DBTPV","---",BX+228,BY+32,8,C_AMBER,"Arial");
   _DR("HP_DBBAR",BX,BY+48,334,4,C_LINE);_DR("HP_DBBF",BX,BY+48,1,4,C_AMBER);

   int PKX=X+8,PKY=Y+304;
   _DL("HP_BKL",  "BPK",       PKX,    PKY,   8,C_DIM,"Arial");
   _DL("HP_BKLV", "---",       PKX+32, PKY,   8,C_LABEL,"Arial");
   _DL("HP_BK1L", "BUY:",      PKX,    PKY+15,7,C_DIM,"Arial");
   _DL("HP_BK1V", "$0.00",     PKX+28, PKY+15,8,C_GREEN,"Arial");
   _DL("HP_BK1T", "/ $0.00",   PKX+75, PKY+15,7,C_DIM,"Arial");
   _DL("HP_BK2L", "SELL:",     PKX+150,PKY+15,7,C_DIM,"Arial");
   _DL("HP_BK2V", "$0.00",     PKX+180,PKY+15,8,C_GREEN,"Arial");
   _DL("HP_BK2T", "/ $0.00",   PKX+227,PKY+15,7,C_DIM,"Arial");
   _DL("HP_BKCL", "closed:",   PKX,    PKY+32,7,C_DIM,"Arial");
   _DL("HP_BKCV", "B:0 S:0",   PKX+42, PKY+32,7,C_LABEL,"Arial");

   int GX=X+346,GY=Y+304;
   _DR("HP_GBG",  GX-6,Y+300,342,52,C_PANEL,C_LINE);
   _DL("HP_GL",   "Guardian",  GX,   GY,   8,C_DIM,"Arial");
   _DL("HP_GS",   "OFF",       GX+55,GY,   8,C_DIM,"Arial");
   _DL("HP_GV",   "",          GX,   GY+15,8,C_LABEL,"Arial");
   _DL("HP_GV2",  "",          GX,   GY+30,7,C_DIM,"Arial");

   _DL("HP_FTL","HybridPro v"+EA_VER+" | "+_Symbol,X+12,Y+363,7,C_DIM,"Arial");
   _DL("HP_FTR","Expiry: "+EXPIRY_STR,             X+500,Y+363,7,C_DIM,"Arial");
   ChartRedraw();
}

void UpdDB()
{
   if(MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE))return;

   int spr=(int)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
   color sc=(spr<50)?C_GREEN:(spr<200)?C_AMBER:C_RED;
   _DS("HP_SP",StringFormat("SPR:%d pts",spr),sc);
   _DS("HP_AT",StringFormat("ATR:%.0f pts",gATR/_Point),C_LABEL);
   _DS("HP_TM",TimeToString(TimeCurrent(),TIME_SECONDS),C_LABEL);
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double bal=AccountInfoDouble(ACCOUNT_BALANCE);
   double flt=eq-bal;
   _DS("HP_EQ",StringFormat("EQ:$%.0f",eq),C_LABEL);
   _DS("HP_BAL",StringFormat("BAL:$%.0f",bal),C_LABEL);
   _DS("HP_FLOAT",StringFormat("FLOAT:%+.2f",flt),(flt>=0)?C_GREEN:C_RED);

   double totPNL=PNL(MAGIC_1)+PNL(MAGIC_2)+PNL(MAGIC_3);
   _DS("HP_A0V",StringFormat("%+.2f",totPNL),(totPNL>=0)?C_GREEN:C_RED);
   _DS("HP_A0S",StringFormat("Float: %+.2f",flt),(flt>=0)?C_GREEN:C_RED);
   _DS("HP_A1V",StringFormat("$%.0f",eq),C_WHITE);
   _DS("HP_A1S",StringFormat("Balance: $%.0f",bal),C_DIM);
   double dd=DD();
   color ddC=(dd<5)?C_GREEN:(dd<15)?C_AMBER:C_RED;
   _DS("HP_A2V",StringFormat("%.2f%%",dd),ddC);
   _DS("HP_A2S",StringFormat("Max: %.2f%%",gMaxDD),C_DIM);
   double totLot=gDailyLotM1+gDailyLotM2+gDailyLotM3;
   int totOrd=gDailyOrdersM1+gDailyOrdersM2+gDailyOrdersM3;
   _DS("HP_A3V",StringFormat("%.2f",totLot),C_AMBER);
   _DS("HP_A3S",StringFormat("Orders: %d",totOrd),C_DIM);

   double p1=PNL(MAGIC_1);int c1=CP(MAGIC_1);
   string dir1=(sM1.dir==1)?"BUY":(sM1.dir==-1)?"SELL":"BIDIR";
   string rnd1=sM1.active?"● ON":"○ off";
   if(gG.active&&(int)gG.target==MAGIC_1&&gG.victimStopped) rnd1="⏸ HOLD";
   _DS("HP_1P",StringFormat("%+.2f",p1),(p1>=0)?C_GREEN:C_RED);
   _DS("HP_1O",IntegerToString(c1),C_LABEL);
   _DS("HP_1T",StringFormat("$%.1f",TPReq(MAGIC_1)),C_LABEL);
   _DS("HP_1G",IntegerToString(sM1.cnt),C_LABEL);
   _DS("HP_1D",dir1,(sM1.dir==1)?C_GREEN:(sM1.dir==-1)?C_RED:C_LABEL);
   _DS("HP_1R",rnd1,(rnd1=="⏸ HOLD")?C_AMBER:sM1.active?C_GREEN:C_DIM);
   _DS("HP_1S",StringFormat("%.2f",gDailyLotM1),C_LABEL);

   double p2=PNL(MAGIC_2);int c2=CP(MAGIC_2);
   string rnd2=gG.active?(gG.resumeMode?"P3:RESUME":gG.reversed?"P2:SWITCH":"P1:COUNTER"):sM2.active?"● ON":"○ off";
   color rc2=gG.active?C_GUARD:sM2.active?C_GREEN:C_DIM;
   _DS("HP_2P",StringFormat("%+.2f",p2),(p2>=0)?C_GREEN:C_RED);
   _DS("HP_2O",IntegerToString(c2),C_LABEL);
   _DS("HP_2T",StringFormat("$%.1f",TPReq(MAGIC_2)),C_LABEL);
   _DS("HP_2G",IntegerToString(sM2.cnt),C_LABEL);
   _DS("HP_2D",(sM2.dir==1)?"BUY":(sM2.dir==-1)?"SELL":"BIDIR",(sM2.dir==1)?C_GREEN:(sM2.dir==-1)?C_RED:C_LABEL);
   _DS("HP_2R",rnd2,rc2);
   _DS("HP_2S",StringFormat("%.2f",gDailyLotM2),C_LABEL);

   double p3=PNL(MAGIC_3);int c3=CP(MAGIC_3);
   string dir3=(sM3.dir==1)?"BUY":(sM3.dir==-1)?"SELL":"BIDIR";
   string rnd3=sM3.active?"● ON":"○ off";
   if(gG.active&&(int)gG.target==MAGIC_3&&gG.victimStopped) rnd3="⏸ HOLD";
   _DS("HP_3P",StringFormat("%+.2f",p3),(p3>=0)?C_GREEN:C_RED);
   _DS("HP_3O",IntegerToString(c3),C_LABEL);
   _DS("HP_3T",StringFormat("$%.1f",TPReq(MAGIC_3)),C_LABEL);
   _DS("HP_3G",IntegerToString(sM3.cnt),C_LABEL);
   _DS("HP_3D",dir3,(sM3.dir==1)?C_GREEN:(sM3.dir==-1)?C_RED:C_LABEL);
   _DS("HP_3R",rnd3,(rnd3=="⏸ HOLD")?C_AMBER:sM3.active?C_GREEN:C_DIM);
   _DS("HP_3S",StringFormat("%.2f",gDailyLotM3),C_LABEL);

   _DS("HP_DDV",StringFormat("%.2f%%",dd),ddC);
   int ddW=(int)(MathMin(dd/30.0,1.0)*316.0);if(ddW<1)ddW=1;
   ObjectSetInteger(0,"HP_DDF",OBJPROP_XSIZE,ddW);
   ObjectSetInteger(0,"HP_DDF",OBJPROP_COLOR,ddC);
   ObjectSetInteger(0,"HP_DDF",OBJPROP_BGCOLOR,ddC);
   int mxW=(int)(MathMin(gMaxDD/30.0,1.0)*316.0);if(mxW<1)mxW=1;
   ObjectSetInteger(0,"HP_DDMF",OBJPROP_XSIZE,mxW);
   _DS("HP_DDMV",StringFormat("%.2f%%",gMaxDD),C_AMBER);
   _DS("HP_DDPV",StringFormat("$%.0f",gPeak),C_LABEL);

   bool hasDebt=(gD1>0||gD2>0||gD3>0||gDG>0);
   _DS("HP_DB1V",StringFormat("$%.2f",gD1),(gD1>0)?C_AMBER:C_GREEN);
   _DS("HP_DB2V",StringFormat("$%.2f",gD2),(gD2>0)?C_AMBER:C_GREEN);
   _DS("HP_DB3V",StringFormat("$%.2f",gD3),(gD3>0)?C_AMBER:C_GREEN);
   _DS("HP_DBGV",StringFormat("$%.2f",gDG),hasDebt?C_AMBER:C_GREEN);
   double tpAdj=gD1+gD2+gD3+gDG;
   _DS("HP_DBTPV",StringFormat("+$%.2f",tpAdj),(tpAdj>0)?C_AMBER:C_GREEN);
   int dbW=(int)(MathMin(tpAdj/(AccountInfoDouble(ACCOUNT_BALANCE)*0.05),1.0)*334.0);if(dbW<1)dbW=1;
   ObjectSetInteger(0,"HP_DBBF",OBJPROP_XSIZE,dbW);
   ObjectSetInteger(0,"HP_DBBF",OBJPROP_COLOR,(tpAdj>0)?C_AMBER:C_GREEN);
   ObjectSetInteger(0,"HP_DBBF",OBJPROP_BGCOLOR,(tpAdj>0)?C_AMBER:C_GREEN);

   _DS("HP_BKLV",StringFormat("slots B:%d S:%d",ArraySize(gBB)>0?1:0,ArraySize(gBS)>0?1:0),C_LABEL);
   _DS("HP_BK1V",StringFormat("$%.2f",gBBTP),(gBBTP>0)?C_GREEN:C_LABEL);
   _DS("HP_BK1T",StringFormat("/ $%.0f",BPKBuyTP),C_DIM);
   _DS("HP_BK2V",StringFormat("$%.2f",gBSTP),(gBSTP>0)?C_GREEN:C_LABEL);
   _DS("HP_BK2T",StringFormat("/ $%.0f",BPKSellTP),C_DIM);
   _DS("HP_BKCV",StringFormat("B:%d S:%d",gBBC,gBSC),C_LABEL);

   if(gG.active){
      int runtime=(int)(TimeCurrent()-gG.startT);
      string phase=gG.resumeMode?"P3:RESUME":gG.reversed?"P2:SWITCH":"P1:COUNTER";
      string vic=((int)gG.target==MAGIC_1)?"M1":"M3";
      string gdir=(gG.dir==1)?"BUY":"SELL";
      string stopped=gG.victimStopped?"[HOLD]":"";
      _DS("HP_GS","● "+phase,C_GUARD);
      _DS("HP_GV",StringFormat("Victim:%s%s Dir:%s Grid:[%d] abs:%d trigP:%.2f",
          vic,stopped,gdir,gG.cnt,gG.totalAbs,gG.trigPrice),C_AMBER);
      string combStr=StringFormat("Runtime:%02d:%02d resumeP:%.2f",
          runtime/60,runtime%60,gG.resumePrice);
      _DS("HP_GV2",combStr,C_LABEL);
      ObjectSetInteger(0,"HP_GBG",OBJPROP_BGCOLOR,C_GUARD_BG);
   }else{
      _DS("HP_GS","OFF",C_DIM);_DS("HP_GV","",C_DIM);_DS("HP_GV2","",C_DIM);
      ObjectSetInteger(0,"HP_GBG",OBJPROP_BGCOLOR,C_PANEL);
   }
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| OnInit / OnDeinit / OnTick                                       |
//+------------------------------------------------------------------+
int OnInit()
{
   if(TimeCurrent()>=StringToTime(EXPIRY_STR)){Print("[Init] Expired");return INIT_FAILED;}
   gs1=MathMax(GS1,5);gs2=MathMax(GS2,5);gs3=MathMax(GS3,5);
   T1.SetExpertMagicNumber(MAGIC_1);T1.SetDeviationInPoints(Slip);
   T2.SetExpertMagicNumber(MAGIC_2);T2.SetDeviationInPoints(Slip);
   T3.SetExpertMagicNumber(MAGIC_3);T3.SetDeviationInPoints(Slip);
   hATR=iATR(_Symbol,PERIOD_CURRENT,14);
   if(hATR==INVALID_HANDLE){Print("[Init] ATR fail");return INIT_FAILED;}
   if(UseADX){hADX=iADX(_Symbol,ADXTF,ADXPer);if(hADX==INVALID_HANDLE){Print("[Init] ADX fail");return INIT_FAILED;}}
   gPeak=AccountInfoDouble(ACCOUNT_EQUITY);gMaxDD=0;
   gD1=gD2=gD3=gDG=0;gLastAbs=0;
   ArrayResize(gBB,MathMax(BPKBuy,1));  for(int i=0;i<ArraySize(gBB);i++)gBB[i].valid=false;
   ArrayResize(gBS,MathMax(BPKSell,1)); for(int i=0;i<ArraySize(gBS);i++)gBS[i].valid=false;
   gBBTP=gBSTP=0;gBBC=gBSC=0;
   gG.active=false;gG.target=GT_NONE;gG.dir=0;gG.lastPrice=0;
   gG.cnt=0;gG.startT=0;gG.lastOrderT=0;gG.totalAbs=0;
   gG.trigPrice=0;gG.victimStopped=false;gG.reversed=false;gG.resumeMode=false;gG.resumePrice=0;
   RR(sM1);RR(sM2);RR(sM3);
   gBar=gBarM1=gBarM2=0;
   gROTime1=gROTime2=gROTime3=0;
   gRODir1=gRODir2=gRODir3=0;
   gDailyLotM1=gDailyLotM2=gDailyLotM3=0;
   gDailyOrdersM1=gDailyOrdersM2=gDailyOrdersM3=0;
   gLastDayReset=0;
   InitDB();
   PrintFormat("HybridPro V%s OK. Expiry=%s",EA_VER,EXPIRY_STR);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hATR!=INVALID_HANDLE)IndicatorRelease(hATR);
   if(hADX!=INVALID_HANDLE)IndicatorRelease(hADX);
   if(!MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_VISUAL_MODE))
      ObjectsDeleteAll(0,"HP_");
}

void OnTick()
{
   if(TimeCurrent()>=StringToTime(EXPIRY_STR))return;
   double b[1];
   if(CopyBuffer(hATR,0,0,1,b)==1)gATR=b[0];
   if(UseADX&&hADX!=INVALID_HANDLE&&CopyBuffer(hADX,0,0,1,b)==1)gADX=b[0];
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq>gPeak)gPeak=eq;
   double dd=DD();if(dd>gMaxDD)gMaxDD=dd;
   ChkReset();
   if(UseBPK){UpdBPK();ChkBPK();}
   ChkDDA();
   ProcGuard();
   ProcReOpen();
   ChkSepTP();ChkTotTP();ChkTwoTP();
   ProcSig();
   ChkG1();ChkG2();ChkG3();
   UpdateDailyStats();
   UpdDB();
}
