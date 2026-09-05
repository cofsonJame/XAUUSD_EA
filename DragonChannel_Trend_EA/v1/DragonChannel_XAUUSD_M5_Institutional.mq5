//+------------------------------------------------------------------+
//| DragonChannel_XAUUSD_M5_Institutional.mq5                        |
//| XAUUSD M5 trend-following EA based on DragonChannel.mq5          |
//| Closed-bar execution, ATR risk control, trend/sideways filter   |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"

#include <Trade/Trade.mqh>
CTrade trade;

//========================= Inputs ===================================
input group "=== Core ==="
input double InpLots              = 0.10;     // Initial/fixed lot
input ulong  InpMagic              = 25090501;
input int    InpDeviationPoints   = 30;       // Max slippage, points
input bool   InpOnlyXAUUSD         = true;     // Restrict to gold symbols
input bool   InpOnlyM5             = true;     // Restrict to M5

input group "=== DragonChannel ==="
input string InpDragonName        = "DragonChannel";
input int    InpMinTrendBars       = 2;        // Consecutive closed bars in trend
input bool   InpRequireBreakout    = true;     // Close beyond channel
input double InpBreakoutATR        = 0.05;     // Extra breakout buffer = ATR*x

input group "=== ATR Risk ==="
input int    InpATRPeriod          = 14;
input double InpSL_ATR             = 1.8;      // Initial SL = ATR*x
input double InpTP_ATR             = 0.0;      // 0 = no fixed TP
input double InpTrailStartATR      = 1.2;      // Start trailing after profit ATR*x
input double InpTrailATR           = 1.4;      // Trailing distance ATR*x
input double InpBreakEvenATR       = 1.0;      // Move SL to BE after profit ATR*x
input double InpBEOffsetATR        = 0.10;     // BE offset ATR*x

input group "=== Trend Confirmation ==="
input bool   InpUseHTF             = true;
input ENUM_TIMEFRAMES InpHTF       = PERIOD_M15;
input int    InpHTF_ATRPeriod      = 14;
input double InpMinChannelATR      = 0.20;     // Avoid very narrow channel
input double InpMinATRPoints       = 0.0;      // 0 = disabled

input group "=== Trading Filters ==="
input double InpMaxSpreadPoints    = 80;       // XAUUSD points
input int    InpCooldownBars       = 2;
input int    InpMaxPositions       = 1;
input bool   InpCloseOnSideways    = true;
input bool   InpCloseOnTrendFlip   = true;
input bool   InpNoFridayLate       = true;
input int    InpFridayStopHour     = 20;       // Server time
input int    InpFridayStopMinute   = 30;

input group "=== Daily Protection ==="
input double InpMaxDailyLossPct    = 3.0;      // Equity drawdown from day-start
input int    InpMaxTradesPerDay    = 12;
input bool   InpBlockAfterDailyLoss= true;

input group "=== Session ==="
input bool   InpUseSession         = false;
input int    InpSessionStartHour   = 7;
input int    InpSessionStartMinute = 0;
input int    InpSessionEndHour     = 23;
input int    InpSessionEndMinute   = 30;

//========================= Globals =================================
int      g_dragon = INVALID_HANDLE;
int      g_atr    = INVALID_HANDLE;
int      g_htfAtr = INVALID_HANDLE;
datetime g_lastBar = 0;
datetime g_lastEntryBar = 0;
double   g_dayStartEquity = 0.0;
int      g_dayKey = -1;
int      g_tradesToday = 0;

// Dragon buffers from supplied indicator:
// 0 Line1, 1 Line2, 2 Line3, 3 Line4, 4 Gray upper, 5 Gray lower,
// 10 belt0, 11 belt1, 12 belt2, 13 belt3, 14 belt4,
// 15 slld_0, 16 slld_8.
double B(int buffer,int shift)
{
   double v[];
   if(CopyBuffer(g_dragon,buffer,shift,1,v)!=1) return EMPTY_VALUE;
   return v[0];
}
double ATR(int shift=1)
{
   double v[];
   if(CopyBuffer(g_atr,0,shift,1,v)!=1) return 0.0;
   return v[0];
}
double HTFATR(int shift=1)
{
   double v[];
   if(CopyBuffer(g_htfAtr,0,shift,1,v)!=1) return 0.0;
   return v[0];
}

bool IsNewBar()
{
   datetime t=iTime(_Symbol,PERIOD_M5,0);
   if(t==0) return false;
   if(t!=g_lastBar){ g_lastBar=t; return true; }
   return false;
}

bool IsGold()
{
   string s=_Symbol;
   StringToUpper(s);
   return (StringFind(s,"XAUUSD")>=0 || StringFind(s,"GOLD")>=0);
}

int DayKey()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   return dt.year*10000+dt.mon*100+dt.day;
}
void RefreshDayState()
{
   int k=DayKey();
   if(k!=g_dayKey)
   {
      g_dayKey=k;
      g_dayStartEquity=AccountInfoDouble(ACCOUNT_EQUITY);
      g_tradesToday=0;
   }
}
double DailyDDPct()
{
   if(g_dayStartEquity<=0) return 0;
   return 100.0*(g_dayStartEquity-AccountInfoDouble(ACCOUNT_EQUITY))/g_dayStartEquity;
}

bool SessionOK()
{
   if(!InpUseSession) return true;
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   int now=dt.hour*60+dt.min;
   int a=InpSessionStartHour*60+InpSessionStartMinute;
   int b=InpSessionEndHour*60+InpSessionEndMinute;
   if(a<=b) return now>=a && now<=b;
   return now>=a || now<=b;
}
bool FridayOK()
{
   if(!InpNoFridayLate) return true;
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   if(dt.day_of_week!=5) return true;
   int now=dt.hour*60+dt.min;
   return now < InpFridayStopHour*60+InpFridayStopMinute;
}
bool SpreadOK()
{
   MqlTick tk; if(!SymbolInfoTick(_Symbol,tk)) return false;
   double spreadPts=(tk.ask-tk.bid)/_Point;
   return spreadPts<=InpMaxSpreadPoints;
}
bool DailyRiskOK()
{
   if(InpBlockAfterDailyLoss && DailyDDPct()>=InpMaxDailyLossPct) return false;
   if(InpMaxTradesPerDay>0 && g_tradesToday>=InpMaxTradesPerDay) return false;
   return true;
}

bool GetTrend(int shift, bool &up, bool &down, bool &sideways)
{
   double l1=B(0,shift), l2=B(1,shift), su=B(15,shift), sl=B(16,shift);
   if(l1==EMPTY_VALUE || l2==EMPTY_VALUE || su==EMPTY_VALUE || sl==EMPTY_VALUE)
      return false;
   up      = (l2>su && l1>sl);
   down    = (l2<su && l1<sl);
   sideways= (!up && !down);
   return true;
}

double Upper(int shift)
{
   double l1=B(0,shift),l2=B(1,shift);
   return MathMax(l1,l2);
}
double Lower(int shift)
{
   double l1=B(0,shift),l2=B(1,shift);
   return MathMin(l1,l2);
}

bool HTFTrendOK(bool wantLong)
{
   if(!InpUseHTF) return true;
   // HTF filter uses closed M15 candles: EMA-like ATR slope + price location.
   // This is deliberately conservative: price must be on the correct side
   // of the previous M15 close by at least 0.10 ATR.
   double atr=HTFATR(1);
   if(atr<=0) return false;
   double c=iClose(_Symbol,InpHTF,1);
   double c2=iClose(_Symbol,InpHTF,2);
   if(c<=0 || c2<=0) return false;
   if(wantLong)  return c>c2 && iClose(_Symbol,PERIOD_M5,1)>c-0.10*atr;
   else          return c<c2 && iClose(_Symbol,PERIOD_M5,1)<c+0.10*atr;
}

int CountOurPositions()
{
   int n=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC)==InpMagic) n++;
   }
   return n;
}

void CloseOurPositions(string reason)
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      trade.PositionClose(ticket,InpDeviationPoints);
   }
}

bool ModifySL(ulong ticket,double sl)
{
   if(!PositionSelectByTicket(ticket)) return false;
   double tp=PositionGetDouble(POSITION_TP);
   return trade.PositionModify(ticket,sl,tp);
}

void ManagePositions()
{
   double atr=ATR(1);
   if(atr<=0) return;
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);

   bool up,down,side;
   if(!GetTrend(1,up,down,side)) return;

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;

      long type=PositionGetInteger(POSITION_TYPE);
      double open=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl=PositionGetDouble(POSITION_SL);
      double tp=PositionGetDouble(POSITION_TP);

      if(type==POSITION_TYPE_BUY)
      {
         double profitDist=bid-open;
         if((InpCloseOnSideways && side) || (InpCloseOnTrendFlip && down))
         {
            trade.PositionClose(ticket,InpDeviationPoints);
            continue;
         }

         double newSL=sl;
         if(profitDist>=InpBreakEvenATR*atr)
         {
            double be=open+InpBEOffsetATR*atr;
            if(sl==0 || be>newSL) newSL=be;
         }
         if(profitDist>=InpTrailStartATR*atr)
         {
            double tr=bid-InpTrailATR*atr;
            if(sl==0 || tr>newSL) newSL=tr;
         }
         double minDist=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
         if(newSL>0 && newSL<bid-minDist)
         {
            newSL=NormalizeDouble(newSL,_Digits);
            if(sl==0 || newSL>sl+_Point) ModifySL(ticket,newSL);
         }
      }
      else if(type==POSITION_TYPE_SELL)
      {
         double profitDist=open-ask;
         if((InpCloseOnSideways && side) || (InpCloseOnTrendFlip && up))
         {
            trade.PositionClose(ticket,InpDeviationPoints);
            continue;
         }

         double newSL=sl;
         if(profitDist>=InpBreakEvenATR*atr)
         {
            double be=open-InpBEOffsetATR*atr;
            if(sl==0 || be<newSL) newSL=be;
         }
         if(profitDist>=InpTrailStartATR*atr)
         {
            double tr=ask+InpTrailATR*atr;
            if(sl==0 || tr<newSL) newSL=tr;
         }
         double minDist=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
         if(newSL>ask+minDist)
         {
            newSL=NormalizeDouble(newSL,_Digits);
            if(sl==0 || newSL<sl-_Point) ModifySL(ticket,newSL);
         }
      }
   }
}

bool BuildEntry(bool wantLong)
{
   double atr=ATR(1);
   if(atr<=0) return false;
   if(InpMinATRPoints>0 && atr/_Point<InpMinATRPoints) return false;

   // Channel width: a very narrow Dragon channel is treated as chop.
   double width=MathAbs(B(0,1)-B(1,1));
   if(width < InpMinChannelATR*atr) return false;

   bool up1,down1,side1;
   if(!GetTrend(1,up1,down1,side1)) return false;

   int consecutive=0;
   for(int s=1;s<=InpMinTrendBars;s++)
   {
      bool u,d,x;
      if(!GetTrend(s,u,d,x)) return false;
      if(wantLong && u) consecutive++;
      else if(!wantLong && d) consecutive++;
      else break;
   }
   if(consecutive<InpMinTrendBars) return false;

   double c1=iClose(_Symbol,PERIOD_M5,1);
   double c2=iClose(_Symbol,PERIOD_M5,2);
   double upper1=Upper(1), upper2=Upper(2);
   double lower1=Lower(1), lower2=Lower(2);

   if(InpRequireBreakout)
   {
      if(wantLong)
      {
         if(!(c1>upper1+InpBreakoutATR*atr && c2<=upper2+InpBreakoutATR*atr))
            return false;
      }
      else
      {
         if(!(c1<lower1-InpBreakoutATR*atr && c2>=lower2-InpBreakoutATR*atr))
            return false;
      }
   }

   if(!HTFTrendOK(wantLong)) return false;

   if(g_lastEntryBar>0)
   {
      int bars=iBarShift(_Symbol,PERIOD_M5,g_lastEntryBar,false);
      if(bars>=0 && bars<InpCooldownBars) return false;
   }

   MqlTick tk; if(!SymbolInfoTick(_Symbol,tk)) return false;
   double price=wantLong?tk.ask:tk.bid;
   double sl=wantLong ? price-InpSL_ATR*atr : price+InpSL_ATR*atr;
   double tp=0.0;
   if(InpTP_ATR>0) tp=wantLong ? price+InpTP_ATR*atr : price-InpTP_ATR*atr;

   long stops=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double minDist=stops*_Point;
   if(wantLong)
   {
      if(price-sl<minDist) sl=price-minDist;
      if(tp>0 && tp-price<minDist) tp=price+minDist;
   }
   else
   {
      if(sl-price<minDist) sl=price+minDist;
      if(tp>0 && price-tp<minDist) tp=price-minDist;
   }

   sl=NormalizeDouble(sl,_Digits);
   if(tp>0) tp=NormalizeDouble(tp,_Digits);

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   bool ok=false;
   if(wantLong) ok=trade.Buy(InpLots,_Symbol,0.0,sl,tp,"Dragon M5 LONG");
   else         ok=trade.Sell(InpLots,_Symbol,0.0,sl,tp,"Dragon M5 SHORT");

   if(ok)
   {
      g_lastEntryBar=iTime(_Symbol,PERIOD_M5,1);
      g_tradesToday++;
   }
   return ok;
}

int OnInit()
{
   if(InpOnlyM5 && _Period!=PERIOD_M5)
   {
      Print("Dragon M5 EA: attach to M5 chart only.");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpOnlyXAUUSD && !IsGold())
   {
      Print("Dragon M5 EA: this EA is restricted to XAUUSD/GOLD.");
      return INIT_PARAMETERS_INCORRECT;
   }

   // Uses the supplied DragonChannel indicator with its native default inputs.
   g_dragon=iCustom(_Symbol,PERIOD_M5,InpDragonName);
   if(g_dragon==INVALID_HANDLE)
   {
      Print("Failed to load DragonChannel: ",InpDragonName,
            ". Compile DragonChannel.mq5 first and place the EX5 in Indicators.");
      return INIT_FAILED;
   }

   g_atr=iATR(_Symbol,PERIOD_M5,InpATRPeriod);
   g_htfAtr=iATR(_Symbol,InpHTF,InpHTF_ATRPeriod);
   if(g_atr==INVALID_HANDLE || g_htfAtr==INVALID_HANDLE)
      return INIT_FAILED;

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   RefreshDayState();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_dragon!=INVALID_HANDLE) IndicatorRelease(g_dragon);
   if(g_atr!=INVALID_HANDLE) IndicatorRelease(g_atr);
   if(g_htfAtr!=INVALID_HANDLE) IndicatorRelease(g_htfAtr);
}

void OnTick()
{
   RefreshDayState();

   // Manage open trades on every tick; entries are closed-bar only.
   ManagePositions();

   if(!IsNewBar()) return;

   if(InpOnlyM5 && _Period!=PERIOD_M5) return;
   if(InpOnlyXAUUSD && !IsGold()) return;
   if(!SessionOK() || !FridayOK() || !SpreadOK() || !DailyRiskOK()) return;

   if(CountOurPositions()>=InpMaxPositions) return;

   bool up,down,side;
   if(!GetTrend(1,up,down,side)) return;

   // No entry in sideways channel.
   if(side) return;

   if(up) BuildEntry(true);
   else if(down) BuildEntry(false);
}
//+------------------------------------------------------------------+
