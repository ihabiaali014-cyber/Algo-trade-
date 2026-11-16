//+------------------------------------------------------------------+
//|                                                 ORB_NY_FTMO.mq5  |
//|  Opening Range Breakout - ouverture de New York (US100 / NAS100) |
//|  avec garde-fous conformes aux règles FTMO.                       |
//+------------------------------------------------------------------+
//  Logique (voir docs/ORB_NY_FTMO.md) :
//   1. Opening range (OR) = plus haut / plus bas des N premières minutes
//      après 9h30 heure de New York (15 min par défaut).
//   2. Filtres : taille du range entre X et Y fois l'ATR journalier,
//      tendance journalière (clôture d'hier vs EMA20 journalière).
//   3. Entrée au marché quand une bougie M5 CLÔTURE au-delà de l'OR
//      (première cassure fraîche), entre la fin de l'OR et 12h00 NY.
//   4. SL de l'autre côté du range (ou milieu) + buffer. TP = 3R.
//      Sortie forcée à 15h50 NY : jamais de position overnight / week-end.
//   5. 1 trade par jour, 0.5 % de risque par trade.
//  Garde-fous FTMO : perte journalière (base = solde de début de journée,
//  limite = % du solde initial, flottant inclus), perte max statique,
//  filtre news haute importance, aucune pratique interdite
//  (pas de HFT, pas de martingale, pas de grid, pas d'arbitrage).
//+------------------------------------------------------------------+
#property copyright   "Algo-trade"
#property version     "1.00"
#property description "ORB session de New York (US100) avec garde-fous FTMO"

#include <Trade\Trade.mqh>

enum ENUM_SERVER_TZ
  {
   TZ_EU_DST = 0,   // GMT+2/+3, heure d'été européenne (FTMO)
   TZ_US_DST = 1,   // GMT+2/+3, heure d'été US (New York +7)
   TZ_FIXED  = 2    // Décalage GMT fixe (voir paramètre)
  };

enum ENUM_SL_MODE
  {
   SL_OPPOSITE = 0, // Autre côté du range
   SL_MID      = 1  // Milieu du range
  };

enum ENUM_TRADE_DIR
  {
   DIR_BOTH  = 0,   // Long et short
   DIR_LONG  = 1,   // Long uniquement
   DIR_SHORT = 2    // Short uniquement
  };

//--- Risque
input group "=== Risque ==="
input double         InpRiskPct          = 0.5;        // Risque par trade (% du solde)
input int            InpMaxTradesDay     = 1;          // Trades max par jour
input ENUM_TRADE_DIR InpDirection        = DIR_BOTH;   // Sens autorisé

//--- FTMO
input group "=== Garde-fous FTMO ==="
input double InpInitialBalance    = 0;     // Solde initial du compte (0 = solde au 1er lancement)
input double InpDailyLossLimit    = 4.0;   // Perte journalière max interne (% solde initial) - FTMO = 5
input double InpMaxLossLimit      = 8.0;   // Perte max interne (% solde initial) - FTMO = 10
input double InpProfitTargetPct   = 0;     // Arrêter après +X % (0 = off). Challenge FTMO = 10
input bool   InpGuardAllPositions = true;  // En cas de dépassement : fermer TOUTES les positions du compte

//--- Horaires
input group "=== Horaires (heure de New York, format HHMM) ==="
input ENUM_SERVER_TZ InpServerTZ    = TZ_EU_DST; // Fuseau du serveur du broker
input int            InpFixedGMT    = 2;         // Décalage GMT si fuseau fixe
input int            InpORStartNY   = 930;       // Début de l'opening range
input int            InpORMinutes   = 15;        // Durée de l'opening range (minutes)
input int            InpLastEntryNY = 1200;      // Dernière entrée possible
input int            InpCloseNY     = 1550;      // Clôture forcée des positions
input bool           InpTradeFriday = true;      // Trader le vendredi

//--- Signal
input group "=== Signal ==="
input ENUM_TIMEFRAMES InpSignalTF    = PERIOD_M5;   // UT de confirmation de la cassure
input bool            InpTrendFilter = true;        // Filtre de tendance journalier
input int             InpTrendEMA    = 20;          // Période EMA journalière
input int             InpATRPeriod   = 14;          // Période ATR journalier
input double          InpMinRangeATR = 0.08;        // Taille min du range (x ATR jour)
input double          InpMaxRangeATR = 0.50;        // Taille max du range (x ATR jour)
input ENUM_SL_MODE    InpSLMode      = SL_OPPOSITE; // Placement du stop loss
input double          InpSLBufferATR = 0.02;        // Buffer du SL (x ATR jour)
input double          InpTP_RR       = 3.0;         // Take profit en R (0 = sortie fin de journée)
input double          InpBE_RR       = 0;           // Break-even à X R (0 = off)

//--- Exécution
input group "=== Exécution ==="
input ulong InpMagic        = 20261116; // Magic number
input int   InpMaxSpreadPts = 0;        // Spread max en points (0 = off)
input int   InpSlippagePts  = 30;       // Slippage max en points

//--- News
input group "=== Filtre news (calendrier MT5, inactif en backtest) ==="
input bool   InpUseNews      = true;   // Bloquer les entrées autour des news fortes
input int    InpNewsBefore   = 5;      // Minutes avant la news
input int    InpNewsAfter    = 5;      // Minutes après la news
input string InpNewsCurrency = "USD";  // Devise surveillée

//+------------------------------------------------------------------+
CTrade   trade;
int      hEMA = INVALID_HANDLE;
int      hATR = INVALID_HANDLE;
string   gv;                      // préfixe des variables globales

datetime g_lastBar     = 0;
datetime g_day         = 0;       // minuit (heure serveur) du jour courant
double   g_initBal     = 0;
double   g_dayStartBal = 0;
bool     g_haltDay     = false;   // limite journalière atteinte
bool     g_haltAll     = false;   // perte max ou objectif atteint

bool     g_orReady = false;       // calcul de l'OR tenté pour aujourd'hui
bool     g_orValid = false;       // OR exploitable (données OK + filtre de taille)
double   g_orHigh  = 0, g_orLow = 0;
double   g_atr     = 0;
int      g_trend   = 0;           // +1 haussier, -1 baissier, 0 neutre
string   g_status  = "";

//+------------------------------------------------------------------+
//| Outils date / fuseau horaire                                      |
//+------------------------------------------------------------------+
datetime MakeDate(int y, int m, int d)
  {
   MqlDateTime s;
   ZeroMemory(s);
   s.year = y; s.mon = m; s.day = d;
   return StructToTime(s);
  }

int DayOfWeek(datetime t)
  {
   MqlDateTime s;
   TimeToStruct(t, s);
   return s.day_of_week;
  }

int YearOf(datetime t)
  {
   MqlDateTime s;
   TimeToStruct(t, s);
   return s.year;
  }

datetime NthSunday(int y, int m, int n)
  {
   datetime first = MakeDate(y, m, 1);
   int d = 1 + ((7 - DayOfWeek(first)) % 7) + 7 * (n - 1);
   return MakeDate(y, m, d);
  }

datetime LastSunday31(int y, int m)       // mars et octobre ont 31 jours
  {
   datetime last = MakeDate(y, m, 31);
   return last - DayOfWeek(last) * 86400;
  }

bool IsUSDST(datetime day)                // 2e dimanche de mars -> 1er dimanche de novembre
  {
   int y = YearOf(day);
   return (day >= NthSunday(y, 3, 2) && day < NthSunday(y, 11, 1));
  }

bool IsEUDST(datetime day)                // dernier dimanche de mars -> dernier dimanche d'octobre
  {
   int y = YearOf(day);
   return (day >= LastSunday31(y, 3) && day < LastSunday31(y, 10));
  }

int ServerGMTOffset(datetime day)
  {
   if(InpServerTZ == TZ_EU_DST) return IsEUDST(day) ? 3 : 2;
   if(InpServerTZ == TZ_US_DST) return IsUSDST(day) ? 3 : 2;
   return InpFixedGMT;
  }

int NYGMTOffset(datetime day) { return IsUSDST(day) ? -4 : -5; }

// Convertit une heure HHMM de New York en heure serveur pour le jour "day"
datetime NYToServer(datetime day, int hhmm)
  {
   int shift = ServerGMTOffset(day) - NYGMTOffset(day);
   return day + (hhmm / 100) * 3600 + (hhmm % 100) * 60 + shift * 3600;
  }

//+------------------------------------------------------------------+
//| Init / Deinit                                                     |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpRiskPct <= 0 || InpRiskPct > 2.0)
     { Print("Risque par trade invalide (0 < risque <= 2 %)."); return INIT_PARAMETERS_INCORRECT; }
   if(InpDailyLossLimit <= 0 || InpDailyLossLimit >= 5.0)
     { Print("La limite journalière interne doit être < 5 % (limite FTMO)."); return INIT_PARAMETERS_INCORRECT; }
   if(InpMaxLossLimit <= 0 || InpMaxLossLimit >= 10.0)
     { Print("La limite de perte max interne doit être < 10 % (limite FTMO)."); return INIT_PARAMETERS_INCORRECT; }
   if(InpORMinutes < 1 || InpORMinutes > 120 || InpMinRangeATR >= InpMaxRangeATR)
     { Print("Paramètres de l'opening range invalides."); return INIT_PARAMETERS_INCORRECT; }
   if(PeriodSeconds(InpSignalTF) > InpORMinutes * 60)
     { Print("L'UT de signal doit être <= à la durée de l'opening range."); return INIT_PARAMETERS_INCORRECT; }

   hEMA = iMA(_Symbol, PERIOD_D1, InpTrendEMA, 0, MODE_EMA, PRICE_CLOSE);
   hATR = iATR(_Symbol, PERIOD_D1, InpATRPeriod);
   if(hEMA == INVALID_HANDLE || hATR == INVALID_HANDLE)
     { Print("Impossible de créer les indicateurs journaliers."); return INIT_FAILED; }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePts);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetMarginMode();

   gv = "ORB_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + IntegerToString((long)InpMagic) + "_";

   // Solde initial (référence des limites FTMO)
   if(InpInitialBalance > 0)
      g_initBal = InpInitialBalance;
   else if(GlobalVariableCheck(gv + "init"))
      g_initBal = GlobalVariableGet(gv + "init");
   else
      g_initBal = AccountInfoDouble(ACCOUNT_BALANCE);
   GlobalVariableSet(gv + "init", g_initBal);

   g_haltAll = GlobalVariableCheck(gv + "haltall") && GlobalVariableGet(gv + "haltall") > 0;

   PrintFormat("ORB NY FTMO prêt. Solde initial de référence : %.2f | limite jour : %.2f %% | limite max : %.2f %%",
               g_initBal, InpDailyLossLimit, InpMaxLossLimit);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(hEMA != INVALID_HANDLE) IndicatorRelease(hEMA);
   if(hATR != INVALID_HANDLE) IndicatorRelease(hATR);
   ObjectsDeleteAll(0, "ORB_");
   Comment("");
  }

//+------------------------------------------------------------------+
//| Tick                                                              |
//+------------------------------------------------------------------+
void OnTick()
  {
   UpdateDay();
   CheckGuards();
   ManageOpenPositions();
   BuildOpeningRange();

   datetime bt = iTime(_Symbol, InpSignalTF, 0);
   if(bt != 0 && bt != g_lastBar)
     {
      g_lastBar = bt;
      OnNewBar();
      UpdatePanel();
     }
  }

//+------------------------------------------------------------------+
//| Nouveau jour serveur (= reset FTMO à minuit CE(S)T)               |
//+------------------------------------------------------------------+
void UpdateDay()
  {
   datetime now = TimeCurrent();
   datetime d   = now - (now % 86400);
   if(d == g_day) return;

   g_day     = d;
   g_orReady = false;
   g_orValid = false;
   g_haltDay = false;

   if(GlobalVariableCheck(gv + "day") && (datetime)GlobalVariableGet(gv + "day") == d)
     {
      // redémarrage de l'EA dans la même journée : on reprend l'ancrage
      g_dayStartBal = GlobalVariableGet(gv + "dbal");
      g_haltDay     = GlobalVariableGet(gv + "haltday") > 0;
     }
   else
     {
      g_dayStartBal = AccountInfoDouble(ACCOUNT_BALANCE);
      GlobalVariableSet(gv + "day", (double)d);
      GlobalVariableSet(gv + "dbal", g_dayStartBal);
      GlobalVariableSet(gv + "haltday", 0);
     }
  }

//+------------------------------------------------------------------+
//| Garde-fous FTMO (vérifiés à chaque tick, flottant inclus)         |
//+------------------------------------------------------------------+
double DailyFloor() { return g_dayStartBal - g_initBal * InpDailyLossLimit / 100.0; }
double MaxFloor()   { return g_initBal * (1.0 - InpMaxLossLimit / 100.0); }

void CheckGuards()
  {
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);

   if(!g_haltAll && eq <= MaxFloor())
     {
      g_haltAll = true;
      GlobalVariableSet(gv + "haltall", 1);
      PrintFormat("STOP : perte max interne atteinte (equity %.2f <= %.2f). Trading arrêté.", eq, MaxFloor());
      CloseAll(InpGuardAllPositions);
     }

   if(!g_haltDay && eq <= DailyFloor())
     {
      g_haltDay = true;
      GlobalVariableSet(gv + "haltday", 1);
      PrintFormat("STOP JOUR : perte journalière interne atteinte (equity %.2f <= %.2f).", eq, DailyFloor());
      CloseAll(InpGuardAllPositions);
     }

   if(!g_haltAll && InpProfitTargetPct > 0 && eq >= g_initBal * (1.0 + InpProfitTargetPct / 100.0))
     {
      g_haltAll = true;
      GlobalVariableSet(gv + "haltall", 1);
      PrintFormat("Objectif de profit atteint (equity %.2f). Positions fermées, trading arrêté.", eq);
      CloseAll(false);
     }
  }

//+------------------------------------------------------------------+
//| Positions                                                         |
//+------------------------------------------------------------------+
bool IsOwn(ulong ticket)
  {
   if(!PositionSelectByTicket(ticket)) return false;
   return (PositionGetString(POSITION_SYMBOL) == _Symbol &&
           (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic);
  }

int CountOwnPositions()
  {
   int c = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t != 0 && IsOwn(t)) c++;
     }
   return c;
  }

void CloseAll(bool allAccount)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!allAccount && !IsOwn(t)) continue;
      if(!trade.PositionClose(t))
         PrintFormat("Échec fermeture #%I64u : %d %s", t, trade.ResultRetcode(), trade.ResultRetcodeDescription());
     }
  }

// Clôture forcée en fin de journée + break-even optionnel
void ManageOpenPositions()
  {
   if(CountOwnPositions() == 0) return;

   datetime now       = TimeCurrent();
   datetime closeTime = NYToServer(g_day, InpCloseNY);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !IsOwn(t)) continue;

      // fin de session, ou position oubliée d'un jour précédent
      if(now >= closeTime || (datetime)PositionGetInteger(POSITION_TIME) < g_day)
        {
         if(!trade.PositionClose(t))
            PrintFormat("Échec clôture fin de journée #%I64u : %s", t, trade.ResultRetcodeDescription());
         continue;
        }

      if(InpBE_RR <= 0) continue;
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      if(sl <= 0) continue;
      long   type = PositionGetInteger(POSITION_TYPE);
      if(type == POSITION_TYPE_BUY && sl < open)
        {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(bid - open >= InpBE_RR * (open - sl))
            trade.PositionModify(t, NormalizePrice(open), tp);
        }
      else if(type == POSITION_TYPE_SELL && sl > open)
        {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         if(open - ask >= InpBE_RR * (sl - open))
            trade.PositionModify(t, NormalizePrice(open), tp);
        }
     }
  }

int TradesToday()
  {
   if(!HistorySelect(g_day, TimeCurrent() + 86400)) return 0;
   int c = 0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong t = HistoryDealGetTicket(i);
      if(t == 0) continue;
      if((ulong)HistoryDealGetInteger(t, DEAL_MAGIC) != InpMagic) continue;
      if(HistoryDealGetString(t, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(t, DEAL_ENTRY) == DEAL_ENTRY_IN) c++;
     }
   return c;
  }

//+------------------------------------------------------------------+
//| Opening range                                                     |
//+------------------------------------------------------------------+
bool ReadDailyIndicators()
  {
   double ema[], atr[];
   if(CopyBuffer(hATR, 0, 1, 1, atr) != 1) return false;
   if(CopyBuffer(hEMA, 0, 1, 1, ema) != 1) return false;
   double prevClose = iClose(_Symbol, PERIOD_D1, 1);
   if(prevClose <= 0 || atr[0] <= 0) return false;
   g_atr   = atr[0];
   g_trend = (prevClose > ema[0]) ? 1 : (prevClose < ema[0] ? -1 : 0);
   return true;
  }

void BuildOpeningRange()
  {
   if(g_orReady) return;

   datetime orStart = NYToServer(g_day, InpORStartNY);
   datetime orEnd   = orStart + InpORMinutes * 60;
   if(TimeCurrent() < orEnd) return;
   if(TimeCurrent() > NYToServer(g_day, InpLastEntryNY)) { g_orReady = true; return; }

   MqlRates r[];
   int n = CopyRates(_Symbol, PERIOD_M1, orStart, orEnd - 1, r);
   if(n < 0) return;                         // historique pas encore chargé : on réessaie
   if(!ReadDailyIndicators()) return;

   g_orReady = true;
   g_orValid = false;

   if(n < (int)MathCeil(InpORMinutes * 0.6) || r[0].time > orStart + 120)
     {
      g_status = "Pas de données complètes sur l'opening range (férié / marché fermé ?)";
      return;
     }

   double hi = r[0].high, lo = r[0].low;
   for(int i = 1; i < n; i++)
     {
      hi = MathMax(hi, r[i].high);
      lo = MathMin(lo, r[i].low);
     }
   g_orHigh = hi;
   g_orLow  = lo;

   double rng = hi - lo;
   if(rng < InpMinRangeATR * g_atr || rng > InpMaxRangeATR * g_atr)
     {
      g_status = StringFormat("Range filtré : %.1f%% de l'ATR (hors %.0f-%.0f%%)",
                              100.0 * rng / g_atr, 100.0 * InpMinRangeATR, 100.0 * InpMaxRangeATR);
      DrawRange(orStart, NYToServer(g_day, InpCloseNY), clrDimGray);
      return;
     }

   g_orValid = true;
   g_status  = StringFormat("Range OK : %.1f%% de l'ATR | tendance %s", 100.0 * rng / g_atr,
                            g_trend > 0 ? "haussière" : (g_trend < 0 ? "baissière" : "neutre"));
   DrawRange(orStart, NYToServer(g_day, InpCloseNY), clrDodgerBlue);
  }

void DrawRange(datetime t1, datetime t2, color clr)
  {
   if(MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE)) return;
   string name = "ORB_" + TimeToString(g_day, TIME_DATE);
   ObjectDelete(0, name);
   if(ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, g_orHigh, t2, g_orLow))
     {
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_FILL, false);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
     }
  }

//+------------------------------------------------------------------+
//| News (comptes FTMO funded standard : pas de trade +-2 min)        |
//+------------------------------------------------------------------+
bool NewsBlocked()
  {
   if(!InpUseNews || MQLInfoInteger(MQL_TESTER)) return false;
   datetime now = TimeTradeServer();
   MqlCalendarValue vals[];
   int n = CalendarValueHistory(vals, now - InpNewsAfter * 60, now + InpNewsBefore * 60, NULL, InpNewsCurrency);
   for(int i = 0; i < n; i++)
     {
      MqlCalendarEvent ev;
      if(CalendarEventById(vals[i].event_id, ev) && ev.importance == CALENDAR_IMPORTANCE_HIGH)
        {
         g_status = "Entrée bloquée : news " + ev.name;
         return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Taille de position                                                |
//+------------------------------------------------------------------+
double NormalizePrice(double p)
  {
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts > 0) p = MathRound(p / ts) * ts;
   return NormalizeDouble(p, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
  }

// Perte (en devise du compte) pour 1 lot entre entry et sl
double LossPerLot(bool isLong, double entry, double sl)
  {
   double pl = 0;
   if(OrderCalcProfit(isLong ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, 1.0, entry, sl, pl) && pl < 0)
      return -pl;
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tv <= 0) tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(ts <= 0 || tv <= 0) return 0;
   return MathAbs(entry - sl) / ts * tv;
  }

double CalcLots(bool isLong, double entry, double sl)
  {
   double lossLot = LossPerLot(isLong, entry, sl);
   if(lossLot <= 0) return 0;

   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPct / 100.0;
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0) step = 0.01;

   double lots = MathFloor(riskMoney / lossLot / step) * step;

   // marge disponible
   double marginLot = 0;
   if(OrderCalcMargin(isLong ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, 1.0, entry, marginLot) && marginLot > 0)
     {
      double maxByMargin = MathFloor(AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.9 / marginLot / step) * step;
      lots = MathMin(lots, maxByMargin);
     }

   if(lots < vmin) return 0;              // le lot minimum dépasserait le risque prévu
   lots = MathMin(lots, vmax);
   int digits = (int)MathMax(0, MathCeil(-MathLog10(step)));
   return NormalizeDouble(lots, digits);
  }

//+------------------------------------------------------------------+
//| Signal : à la clôture de chaque bougie de l'UT de signal          |
//+------------------------------------------------------------------+
void OnNewBar()
  {
   if(!g_orValid || g_haltDay || g_haltAll) return;

   datetime now       = TimeCurrent();
   datetime orEnd     = NYToServer(g_day, InpORStartNY) + InpORMinutes * 60;
   datetime lastEntry = NYToServer(g_day, InpLastEntryNY);
   if(now < orEnd || now > lastEntry) return;
   if(!InpTradeFriday && DayOfWeek(g_day) == 5) return;
   if(CountOwnPositions() > 0) return;
   if(TradesToday() >= InpMaxTradesDay) return;

   MqlRates b[];
   ArraySetAsSeries(b, true);
   if(CopyRates(_Symbol, InpSignalTF, 1, 2, b) < 2) return;   // b[0] = dernière bougie clôturée
   if(b[0].time < orEnd) return;

   bool bullBreak = (b[0].close > g_orHigh && b[1].close <= g_orHigh);
   bool bearBreak = (b[0].close < g_orLow  && b[1].close >= g_orLow);

   bool goLong  = bullBreak && InpDirection != DIR_SHORT && (!InpTrendFilter || g_trend > 0);
   bool goShort = bearBreak && InpDirection != DIR_LONG  && (!InpTrendFilter || g_trend < 0);
   if(!goLong && !goShort) return;

   if(NewsBlocked()) return;

   if(InpMaxSpreadPts > 0 && SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > InpMaxSpreadPts)
     { g_status = "Entrée ignorée : spread trop large"; return; }

   double buf = InpSLBufferATR * g_atr;
   double mid = (g_orHigh + g_orLow) / 2.0;
   double entry, sl, tp;

   if(goLong)
     {
      entry = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      sl    = (InpSLMode == SL_OPPOSITE ? g_orLow : mid) - buf;
      if(entry - sl <= 0) return;
      tp    = InpTP_RR > 0 ? entry + (entry - sl) * InpTP_RR : 0;
     }
   else
     {
      entry = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      sl    = (InpSLMode == SL_OPPOSITE ? g_orHigh : mid) + buf;
      if(sl - entry <= 0) return;
      tp    = InpTP_RR > 0 ? entry - (sl - entry) * InpTP_RR : 0;
     }

   // distance minimale imposée par le broker
   double minDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(MathAbs(entry - sl) < minDist || (tp > 0 && MathAbs(tp - entry) < minDist))
     { g_status = "Entrée ignorée : stop trop proche (stops level)"; return; }

   sl = NormalizePrice(sl);
   if(tp > 0) tp = NormalizePrice(tp);

   double lots = CalcLots(goLong, entry, sl);
   if(lots <= 0) { g_status = "Entrée ignorée : lot minimum > risque autorisé"; return; }

   // Le pire scénario de ce trade ne doit pas pouvoir casser une limite FTMO interne
   double riskMoney = LossPerLot(goLong, entry, sl) * lots;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq - riskMoney <= DailyFloor() || eq - riskMoney <= MaxFloor())
     { g_status = "Entrée ignorée : le SL pourrait dépasser une limite FTMO"; return; }

   bool ok = goLong ? trade.Buy(lots, _Symbol, 0, sl, tp, "ORB long")
                    : trade.Sell(lots, _Symbol, 0, sl, tp, "ORB short");
   if(ok)
      g_status = StringFormat("%s %.2f lots | SL %s | TP %s | risque %.2f",
                              goLong ? "LONG" : "SHORT", lots, DoubleToString(sl, _Digits),
                              tp > 0 ? DoubleToString(tp, _Digits) : "fin de journée", riskMoney);
   else
      g_status = StringFormat("Échec de l'ordre : %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
   Print(g_status);
  }

//+------------------------------------------------------------------+
//| Panneau d'information                                             |
//+------------------------------------------------------------------+
void UpdatePanel()
  {
   if(MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE)) return;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   string s = "ORB New York | FTMO\n";
   s += StringFormat("OR %s -> %s (heure serveur)\n",
                     TimeToString(NYToServer(g_day, InpORStartNY), TIME_MINUTES),
                     TimeToString(NYToServer(g_day, InpORStartNY) + InpORMinutes * 60, TIME_MINUTES));
   s += StringFormat("Equity %.2f | plancher jour %.2f | plancher max %.2f\n", eq, DailyFloor(), MaxFloor());
   s += StringFormat("Résultat du jour : %.2f %% du solde initial\n", 100.0 * (eq - g_dayStartBal) / g_initBal);
   if(g_haltAll)      s += "ÉTAT : ARRÊTÉ (perte max ou objectif)\n";
   else if(g_haltDay) s += "ÉTAT : arrêté pour aujourd'hui\n";
   s += g_status;
   Comment(s);
  }
//+------------------------------------------------------------------+
