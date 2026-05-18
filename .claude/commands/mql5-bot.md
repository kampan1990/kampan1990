# MQL5 Expert Advisor Code Writer

เขียนโค้ด MQL5 Expert Advisor ตามความต้องการ โดยใช้ HybridPro V20 เป็น reference pattern

## วิธีใช้
```
/mql5-bot [คำอธิบาย]
```
ตัวอย่าง:
- `/mql5-bot สร้าง EA grid ทางเดียว MA cross signal`
- `/mql5-bot เพิ่ม trailing stop ใน HybridPro`
- `/mql5-bot สร้าง indicator RSI divergence`

---

## ขั้นตอนการทำงาน

1. **วิเคราะห์ความต้องการ** จาก $ARGUMENTS — ถ้าไม่ครบให้ถามก่อนเขียน:
   - สัญญาณเข้าออก (Signal)
   - จำนวน Magic number ที่ใช้
   - ระบบ Grid / Martingale / TP
   - ฟีเจอร์พิเศษ (Guardian, BPK, DDA ฯลฯ)

2. **เขียนโค้ดตาม standard นี้เสมอ:**

### โครงสร้าง EA มาตรฐาน

```mql5
//+------------------------------------------------------------------+
//| EA_NAME.mq5                                                      |
//+------------------------------------------------------------------+
#property version "1.00"
#property strict
#include <Trade\Trade.mqh>

#define EA_VER  "1.00"
#define EXPIRY_STR "2026.12.31 23:59"

//--- Enums (ถ้ามี)

//--- Structs (ถ้ามี)

//+------------------------------------------------------------------+
//| input parameters                                                 |
//+------------------------------------------------------------------+
input group "=== Magic Numbers ==="
// ...

input group "=== Grid Settings ==="
// ...

input group "=== Lot / Risk ==="
// ...

input group "=== Take Profit ==="
// ...

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade T1;
// ...

//+------------------------------------------------------------------+
//| Helper functions                                                 |
//+------------------------------------------------------------------+
// NLot(), Lot(), DD(), CP(), PNL(), OO() ฯลฯ

//+------------------------------------------------------------------+
//| Signal detection                                                 |
//+------------------------------------------------------------------+
// DetEng(), DetMA(), DetRSI() ฯลฯ

//+------------------------------------------------------------------+
//| Grid / TP logic                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| OnInit / OnDeinit / OnTick                                       |
//+------------------------------------------------------------------+
int OnInit() { ... }
void OnDeinit(const int reason) { ... }
void OnTick() { ... }
```

---

## กฎการเขียนโค้ด

### ความถูกต้อง
- ฟังก์ชันที่ถูกเรียกต้อง **define ก่อน** เสมอ (MQL5 compile top-down)
- ตรวจ `SYMBOL_SPREAD <= MaxSpread` ก่อนเปิดออเดอร์ทุกครั้ง
- ใช้ `PositionSelectByTicket(t)` ก่อน `PositionGetXxx()` เสมอ
- loop positions ต้องวน **ถอยหลัง** `for(int i=PositionsTotal()-1; i>=0; i--)`

### ระบบ Lot
```mql5
double NLot(double v){
   double s=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double mx=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   v=MathFloor(v/s)*s;
   if(v<mn)v=mn; if(v>mx)v=mx;
   return NormalizeDouble(v,2);
}
```

### การเปิดออเดอร์
```mql5
bool OO(int m, int d, double lot){
   if(!CanP(m) || !SpreadOK()) return false;
   CTrade *tr = TR(m);
   bool ok = (d==1) ? tr.Buy(lot,_Symbol,0,0,0,"M"+IntegerToString(m))
                    : tr.Sell(lot,_Symbol,0,0,0,"M"+IntegerToString(m));
   if(!ok) PrintFormat("[OO] FAIL M%d err=%d", m, GetLastError());
   return ok;
}
```

### ระบบ TP (ดึงไม้เสียออกทุกรอบ)
- รวบรวมไม้กำไร → sort มากสุดก่อน
- รวบรวมไม้เสีย → sort เสียมากสุดก่อน
- ต้องปิดไม้กำไรพอ cover `req + loss` เสมอ
- ห้าม TP โดยไม่ดึงไม้เสียออก (ถ้า SelfAbs > 0)

### Breakeven SL
- ใช้ `op + d * BEPts * _Point` (BEPts > 0 = ล็อกกำไร)
- ตรวจว่า SL ใหม่ดีกว่าเดิมก่อน modify เสมอ
- `(d==1) ? (nsl>sl||sl==0) : (nsl<sl||sl==0)`

---

## สัญญาณที่รองรับ

| สัญญาณ | คำอธิบาย |
|---|---|
| `engulfing` | Engulfing candle (pattern ใน HybridPro) |
| `ma_cross` | Moving Average crossover |
| `rsi` | RSI overbought/oversold |
| `bb` | Bollinger Bands breakout |
| `custom` | กำหนดเองตาม logic ที่ระบุ |

---

## การส่งผลลัพธ์

1. เขียนโค้ดสมบูรณ์ลงไฟล์ `.mq5` ในโปรเจกต์
2. สรุปสิ่งที่ implement แล้วและ parameter สำคัญ
3. บอก edge case หรือจุดที่ควรทดสอบ

ถ้า $ARGUMENTS ว่างเปล่า ให้ถามผู้ใช้ว่าต้องการบอทแบบไหนก่อน
