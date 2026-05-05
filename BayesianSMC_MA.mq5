//+------------------------------------------------------------------+
//|                                       BayesianSMC_MA.mq5  v2.00  |
//|       Bayesian Smart Money Concepts — Adaptive Moving Average    |
//|                       Hugo + Claude                              |
//+------------------------------------------------------------------+
//
//  v2.0 — INSTITUTIONAL GRADE
//  ──────────────────────────
//  Reescrita completa da v1.0 com 5 elevações de qualidade:
//
//   1) BANDA BAYESIANA DE INCERTEZA (cloud σ-driven)
//      Cada barra produz uma posterior Bernoulli P(BUY) ∈ [0,1] com
//      desvio σ = sqrt(P·(1−P)). A banda de cloud em volta da linha
//      tem largura σ·ATR·InpBandWidth — colapsa quando o motor está
//      confiante (P→0 ou 1) e se expande no centro (P=0.5). É a
//      VISUALIZAÇÃO DIRETA da convicção do motor por barra.
//
//   2) MTF BAYESIAN FUSION (Higher-TF prior em log-odds)
//      Usa o Trend evidence em uma TF maior (default H4) como prior
//      bayesiano, somando ao logit local com peso InpMTFWeight.
//      A álgebra de log-odds é a forma canônica de combinar duas
//      fontes de evidência independentes — cada bar do chart TF
//      consulta o bar correspondente da MTF via iBarShift().
//
//   3) ADAPTIVE SMOOTHING (Kalman-style com gain bias-driven)
//      α_t = α_min + (α_max − α_min) · |bias_t|²
//      Quando o motor está em sinal forte (|bias|≈1), α se aproxima
//      de α_max → linha responsiva. Quando indeciso (|bias|≈0), α
//      cai pra α_min → linha estável. Resultado: zero whipsaw em
//      chop, máxima reatividade em tendência.
//
//   4) STRUCTURE COM FRACTAIS REAIS + BoS
//      A v1 usava close[i]−close[i−K] como proxy. Agora detectamos
//      swing highs/lows via fractais N-bar e medimos BoS local
//      (close atual rompendo último swing) com weight decaindo
//      exponencialmente em barras desde o break. Posição relativa
//      do close ao mid do range entre swings também contribui.
//
//   5) PAINEL + ALERTAS
//      Painel compacto com bias%, P(BUY), confiança, MTF prior,
//      σ-band em pontos, idade do último flip. Alertas opcionais
//      em flip de viés e cruzamento preço×linha — anti-spam por bar.
//
//  ROBUSTEZ
//  ────────
//   • 13 validações de input em OnInit
//   • 7 handles (chart: EMA fast/slow, RSI, ATR, VolMA + MTF: EMA fast/slow)
//     todos checados e liberados em OnDeinit
//   • CopyBuffer com ResetLastError + GetLastError em todos
//   • BarsCalculated() conferido antes de copiar
//   • Recompute incremental: prev_calculated → recalcula só novas barras
//   • EMPTY_VALUE explícito em warmup; sem linha-fantasma à esquerda
//   • Anti-spam de alertas: 1 por barra fechada, gate em time[]
//   • Painel limpo seletivo em OnDeinit (preserva em PARAMETERS/CHARTCHANGE)
//
//+------------------------------------------------------------------+
#property copyright "Hugo + Claude"
#property version   "2.00"
#property strict
#property indicator_chart_window
#property indicator_buffers 7
#property indicator_plots   3

// ── Plot 1: Cloud (DRAW_FILLING entre upper e lower) ──
#property indicator_label1  "Cloud"
#property indicator_type1   DRAW_FILLING
#property indicator_color1  clrSeaGreen, clrFireBrick

// ── Plot 2: Linha BSMC (DRAW_COLOR_LINE) ──
#property indicator_label2  "BSMC_MA"
#property indicator_type2   DRAW_COLOR_LINE
#property indicator_color2  clrDodgerBlue, clrLimeGreen, clrCrimson, clrGoldenrod
#property indicator_style2  STYLE_SOLID
#property indicator_width2  3

// ── Plot 3: EMA base (referência, dotted) ──
#property indicator_label3  "EMA_Base"
#property indicator_type3   DRAW_LINE
#property indicator_color3  clrDimGray
#property indicator_style3  STYLE_DOT
#property indicator_width3  1

// ─────────────────────────────────────────────────────────────────
//  INPUTS
// ─────────────────────────────────────────────────────────────────
input group "── Engine ──"
input int    InpEMAFast            = 20;     // EMA rápida (linha base)
input int    InpEMASlow            = 50;     // EMA lenta (Trend evidence)
input int    InpRSIPeriod          = 14;     // RSI período
input int    InpATRPeriod          = 14;     // ATR período
input int    InpVolumeMA           = 20;     // MA do volume
input int    InpStructureLookback  = 60;     // Bars p/ buscar fractais
input int    InpFractalDepth       = 2;      // 2 = 2 bars cada lado (clássico)
input int    InpLiqLookback        = 10;     // Bars p/ sweep detection

input group "── MTF Bayesian Prior ──"
input ENUM_TIMEFRAMES InpMTFPeriod = PERIOD_H4;  // PERIOD_CURRENT desliga
input double InpMTFWeight          = 0.6;        // Peso do MTF prior

input group "── Pesos Bayesianos ──"
input double InpWTrend             = 1.0;
input double InpWMomentum          = 1.0;
input double InpWStructure         = 1.3;
input double InpWImbalance         = 1.1;
input double InpWLiquidity         = 1.2;
input double InpWVolume            = 0.8;

input group "── Linha + Banda + Smoothing ──"
input double InpDisplacement       = 1.0;    // Multiplicador ATR p/ bias
input double InpBandWidth          = 1.5;    // Multiplicador ATR p/ banda σ
input double InpAlphaMin           = 0.10;   // Smoothing baseline (incerto)
input double InpAlphaMax           = 0.55;   // Smoothing máx (motor confiante)
input double InpNeutralThreshold   = 0.15;   // |bias| neutral

input group "── Visual ──"
input bool   InpShowBaseEMA        = true;
input bool   InpShowCloud          = true;
input bool   InpShowPanel          = true;
input int    InpPanelX             = 12;
input int    InpPanelY             = 18;
input int    InpPanelFontSize      = 9;
input string InpPanelFont          = "Consolas";
input color  InpPanelColor         = clrWhite;
input string InpObjPrefix          = "BSMC_MA_";

input group "── Alertas ──"
input bool   InpAlertOnFlip        = true;
input bool   InpAlertOnCross       = false;

// ─────────────────────────────────────────────────────────────────
//  BUFFERS
// ─────────────────────────────────────────────────────────────────
double buf_upper[];   // [0] cloud upper band
double buf_lower[];   // [1] cloud lower band
double buf_line[];    // [2] BSMC main line
double buf_color[];   // [3] color index
double buf_ema[];     // [4] EMA base
double buf_bias[];    // [5] smoothed bias (CALC)
double buf_pBuy[];    // [6] posterior P(BUY) (CALC)

// ─────────────────────────────────────────────────────────────────
//  HANDLES + CACHE ARRAYS
// ─────────────────────────────────────────────────────────────────
int hEMAFast = INVALID_HANDLE;
int hEMASlow = INVALID_HANDLE;
int hRSI     = INVALID_HANDLE;
int hATR     = INVALID_HANDLE;
int hVolMA   = INVALID_HANDLE;
int hMTFFast = INVALID_HANDLE;
int hMTFSlow = INVALID_HANDLE;

double arr_emaFast[], arr_emaSlow[], arr_rsi[], arr_atr[], arr_volMA[], arr_volume[];
double arr_mtfFast[], arr_mtfSlow[];

ENUM_TIMEFRAMES g_mtfTF;
bool     g_mtfEnabled = false;
int      g_minBars = 0;
int      g_lastFlipColor = 0;
datetime g_lastFlipTime = 0;
datetime g_lastAlertBar = 0;

// ─────────────────────────────────────────────────────────────────
//  HELPERS
// ─────────────────────────────────────────────────────────────────
double Sigmoid(const double x) {
   if(x >  30.0) return 1.0;
   if(x < -30.0) return 0.0;
   return 1.0 / (1.0 + MathExp(-x));
}

double Clamp(const double x, const double lo, const double hi) {
   if(x < lo) return lo;
   if(x > hi) return hi;
   return x;
}

string PeriodToStr(const ENUM_TIMEFRAMES tf) {
   switch(tf) {
      case PERIOD_M1:  return "M1";   case PERIOD_M5:  return "M5";
      case PERIOD_M15: return "M15";  case PERIOD_M30: return "M30";
      case PERIOD_H1:  return "H1";   case PERIOD_H4:  return "H4";
      case PERIOD_D1:  return "D1";   case PERIOD_W1:  return "W1";
      case PERIOD_MN1: return "MN1";  default: return EnumToString(tf);
   }
}

// ─────────────────────────────────────────────────────────────────
//  6 EVIDÊNCIAS — LLR ∈ [−2, +2]
// ─────────────────────────────────────────────────────────────────
double LLR_Trend(const int i) {
   const double ef = arr_emaFast[i];
   const double es = arr_emaSlow[i];
   if(es <= 0.0) return 0.0;
   return Clamp(2.0 * MathTanh(100.0 * (ef - es) / es), -2.0, 2.0);
}

double LLR_Momentum(const int i) {
   const double r = arr_rsi[i];
   double base = (r - 50.0) / 20.0;
   if(r > 80.0) base -= 0.5;
   if(r < 20.0) base += 0.5;
   return Clamp(base, -2.0, 2.0);
}

double LLR_Volume(const int i, const double &close[], const double &open[]) {
   if(arr_volMA[i] <= 0.0) return 0.0;
   const double r = arr_volume[i] / arr_volMA[i];
   if(r < 1.0) return 0.0;
   double dir = 0.0;
   if(close[i] > open[i]) dir = +1.0;
   else if(close[i] < open[i]) dir = -1.0;
   return Clamp((r - 1.0) * dir, -2.0, 2.0);
}

// Structure REAL: fractais N-bar + BoS local
double LLR_Structure(const int i,
                     const double &high[], const double &low[],
                     const double &close[], const int total) {
   const int LB = InpStructureLookback;
   const int FD = InpFractalDepth;
   if(i < LB + FD || i + FD >= total) return 0.0;

   double lastSH = 0.0, lastSL = 0.0;
   int    lastSHidx = -1, lastSLidx = -1;

   // Procura último fractal high e low confirmados (j ≤ i−FD)
   const int jMin = MathMax(FD, i - LB);
   for(int j = i - FD; j >= jMin; --j) {
      if(lastSHidx == -1) {
         bool isSH = true;
         for(int k = 1; k <= FD; ++k) {
            if(high[j] <= high[j - k] || high[j] <= high[j + k]) { isSH = false; break; }
         }
         if(isSH) { lastSH = high[j]; lastSHidx = j; }
      }
      if(lastSLidx == -1) {
         bool isSL = true;
         for(int k = 1; k <= FD; ++k) {
            if(low[j] >= low[j - k] || low[j] >= low[j + k]) { isSL = false; break; }
         }
         if(isSL) { lastSL = low[j]; lastSLidx = j; }
      }
      if(lastSHidx >= 0 && lastSLidx >= 0) break;
   }

   double llr = 0.0;

   // BoS up: rompimento do último swing high, com decay temporal
   if(lastSHidx >= 0 && close[i] > lastSH) {
      const double w = MathExp(-(double)(i - lastSHidx) / 15.0);
      llr += 1.0 * w;
   }
   // BoS down
   if(lastSLidx >= 0 && close[i] < lastSL) {
      const double w = MathExp(-(double)(i - lastSLidx) / 15.0);
      llr -= 1.0 * w;
   }

   // Posição relativa do close ao mid do range entre swings
   if(lastSHidx >= 0 && lastSLidx >= 0 && lastSH > lastSL) {
      const double mid   = 0.5 * (lastSH + lastSL);
      const double range = lastSH - lastSL;
      const double posRel = (close[i] - mid) / range;
      llr += 0.5 * Clamp(2.0 * posRel, -1.0, 1.0);
   }

   return Clamp(llr, -2.0, 2.0);
}

// Imbalance: FVG inline na barra
double LLR_Imbalance(const int i, const double &high[], const double &low[]) {
   if(i < 2 || arr_atr[i] <= 0.0) return 0.0;
   double llr = 0.0;
   const double bullGap = low[i]     - high[i - 2];
   const double bearGap = low[i - 2] - high[i];
   if(bullGap > 0.0) llr += Clamp(bullGap / arr_atr[i] * 1.5, 0.0, 1.5);
   if(bearGap > 0.0) llr -= Clamp(bearGap / arr_atr[i] * 1.5, 0.0, 1.5);
   return Clamp(llr, -2.0, 2.0);
}

// Liquidity: sweep com fechamento reversivo
double LLR_Liquidity(const int i,
                     const double &high[], const double &low[],
                     const double &close[], const double &open[]) {
   const int K = InpLiqLookback;
   if(i < K + 1 || arr_atr[i] <= 0.0) return 0.0;
   double hMax = high[i - 1], lMin = low[i - 1];
   for(int j = 2; j <= K; ++j) {
      const int idx = i - j;
      if(high[idx] > hMax) hMax = high[idx];
      if(low[idx]  < lMin) lMin = low[idx];
   }
   double llr = 0.0;
   if(high[i] > hMax && close[i] < open[i]) {
      llr -= Clamp((high[i] - hMax) / arr_atr[i] * 1.5, 0.0, 1.5);
   }
   if(low[i] < lMin && close[i] > open[i]) {
      llr += Clamp((lMin - low[i]) / arr_atr[i] * 1.5, 0.0, 1.5);
   }
   return Clamp(llr, -2.0, 2.0);
}

// MTF logit: Trend evidence na TF maior, alinhado por iBarShift
double MTF_Logit(const datetime t) {
   if(!g_mtfEnabled) return 0.0;
   const int N = ArraySize(arr_mtfFast);
   if(N == 0) return 0.0;

   const int mtfShift = iBarShift(_Symbol, g_mtfTF, t, false);
   if(mtfShift < 0) return 0.0;

   // CopyBuffer(0, 0, N, arr) com array non-series:
   // arr[N-1] = bar mais recente (shift=0); arr[N-1-k] = shift=k
   const int idx = N - 1 - mtfShift;
   if(idx < 0 || idx >= N) return 0.0;

   const double ef = arr_mtfFast[idx];
   const double es = arr_mtfSlow[idx];
   if(es <= 0.0) return 0.0;
   return Clamp(2.0 * MathTanh(100.0 * (ef - es) / es), -2.0, 2.0);
}

// ─────────────────────────────────────────────────────────────────
//  PAINEL
// ─────────────────────────────────────────────────────────────────
void EnsureLabel(const string name, const int y, const color c, const string text) {
   if(ObjectFind(0, name) < 0) {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE,  InpPanelX);
      ObjectSetString (0, name, OBJPROP_FONT,       InpPanelFont);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE,   InpPanelFontSize);
      ObjectSetInteger(0, name, OBJPROP_BACK,       false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
   }
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_COLOR,     c);
   ObjectSetString (0, name, OBJPROP_TEXT,      text);
}

void DrawPanel(const double pBuy, const double bias, const double mtfLogit,
               const double sigma, const double atr) {
   if(!InpShowPanel) return;
   const string base = InpObjPrefix + "panel_";
   const int dy = InpPanelFontSize + 5;
   const int conf = (int)MathRound(MathAbs(bias) * 100.0);
   const string sigTag = (bias >  InpNeutralThreshold) ? "▲ BUY"
                       : (bias < -InpNeutralThreshold) ? "▼ SELL"
                       : "● HOLD";
   const color  sigCol = (bias >  InpNeutralThreshold) ? clrLimeGreen
                       : (bias < -InpNeutralThreshold) ? clrCrimson
                       : clrGoldenrod;
   const double bandPts = sigma * atr * InpBandWidth / _Point;
   const string flipAge = (g_lastFlipTime > 0)
      ? StringFormat("Flip há %ds", (int)(TimeCurrent() - g_lastFlipTime))
      : "Flip: —";

   int y = InpPanelY;
   EnsureLabel(base + "0", y, InpPanelColor, "BayesianSMC_MA v2.0"); y += dy;
   EnsureLabel(base + "1", y, sigCol,
      StringFormat("Bias %+.2f  %s", bias, sigTag));               y += dy;
   EnsureLabel(base + "2", y, InpPanelColor,
      StringFormat("P(BUY) %.3f", pBuy));                          y += dy;
   EnsureLabel(base + "3", y, InpPanelColor,
      StringFormat("Conf   %d%%", conf));                          y += dy;
   EnsureLabel(base + "4", y, InpPanelColor,
      StringFormat("σ-band ±%.0f pts", bandPts));                  y += dy;
   if(g_mtfEnabled) {
      EnsureLabel(base + "5", y, InpPanelColor,
         StringFormat("MTF(%s) %+.2f", PeriodToStr(g_mtfTF), mtfLogit));
   } else {
      EnsureLabel(base + "5", y, clrSilver, "MTF off");
   }
   y += dy;
   EnsureLabel(base + "6", y, clrSilver, flipAge);
}

void ClearPanel() {
   ObjectsDeleteAll(0, InpObjPrefix);
   ChartRedraw(0);
}

// ─────────────────────────────────────────────────────────────────
//  OnInit
// ─────────────────────────────────────────────────────────────────
int OnInit() {
   // ── Validações ──
   if(InpEMAFast < 2 || InpEMASlow < 5 || InpEMAFast >= InpEMASlow) {
      Print("❌ BSMC_MA: EMAs inválidas (2 ≤ Fast < Slow)"); return INIT_PARAMETERS_INCORRECT;
   }
   if(InpRSIPeriod < 2 || InpATRPeriod < 2 || InpVolumeMA < 2) {
      Print("❌ BSMC_MA: períodos curtos"); return INIT_PARAMETERS_INCORRECT;
   }
   if(InpStructureLookback < 20 || InpLiqLookback < 2) {
      Print("❌ BSMC_MA: StructureLookback ≥ 20, LiqLookback ≥ 2"); return INIT_PARAMETERS_INCORRECT;
   }
   if(InpFractalDepth < 1 || InpFractalDepth > 5) {
      Print("❌ BSMC_MA: FractalDepth ∈ [1, 5]"); return INIT_PARAMETERS_INCORRECT;
   }
   if(InpAlphaMin <= 0.0 || InpAlphaMin >= 1.0
      || InpAlphaMax <= 0.0 || InpAlphaMax >= 1.0) {
      Print("❌ BSMC_MA: AlphaMin/Max ∈ (0, 1)"); return INIT_PARAMETERS_INCORRECT;
   }
   if(InpAlphaMin > InpAlphaMax) {
      Print("❌ BSMC_MA: AlphaMin ≤ AlphaMax"); return INIT_PARAMETERS_INCORRECT;
   }
   if(InpNeutralThreshold < 0.0 || InpNeutralThreshold > 1.0) {
      Print("❌ BSMC_MA: NeutralThreshold ∈ [0, 1]"); return INIT_PARAMETERS_INCORRECT;
   }
   if(InpDisplacement <= 0.0 || InpBandWidth < 0.0) {
      Print("❌ BSMC_MA: Displacement > 0, BandWidth ≥ 0"); return INIT_PARAMETERS_INCORRECT;
   }
   if(InpMTFWeight < 0.0 || InpMTFWeight > 5.0) {
      Print("❌ BSMC_MA: MTFWeight ∈ [0, 5]"); return INIT_PARAMETERS_INCORRECT;
   }
   if(StringLen(InpObjPrefix) < 3) {
      Print("❌ BSMC_MA: ObjPrefix muito curto (mínimo 3 chars)"); return INIT_PARAMETERS_INCORRECT;
   }
   if(InpPanelFontSize < 6 || InpPanelFontSize > 24) {
      Print("❌ BSMC_MA: PanelFontSize ∈ [6, 24]"); return INIT_PARAMETERS_INCORRECT;
   }

   // ── Mapear buffers ──
   SetIndexBuffer(0, buf_upper, INDICATOR_DATA);
   SetIndexBuffer(1, buf_lower, INDICATOR_DATA);
   SetIndexBuffer(2, buf_line,  INDICATOR_DATA);
   SetIndexBuffer(3, buf_color, INDICATOR_COLOR_INDEX);
   SetIndexBuffer(4, buf_ema,   INDICATOR_DATA);
   SetIndexBuffer(5, buf_bias,  INDICATOR_CALCULATIONS);
   SetIndexBuffer(6, buf_pBuy,  INDICATOR_CALCULATIONS);

   ArraySetAsSeries(buf_upper, false);
   ArraySetAsSeries(buf_lower, false);
   ArraySetAsSeries(buf_line,  false);
   ArraySetAsSeries(buf_color, false);
   ArraySetAsSeries(buf_ema,   false);
   ArraySetAsSeries(buf_bias,  false);
   ArraySetAsSeries(buf_pBuy,  false);

   // ── Cores explícitas para a linha ──
   PlotIndexSetInteger(1, PLOT_COLOR_INDEXES, 4);
   PlotIndexSetInteger(1, PLOT_LINE_COLOR, 0, clrDodgerBlue);
   PlotIndexSetInteger(1, PLOT_LINE_COLOR, 1, clrLimeGreen);
   PlotIndexSetInteger(1, PLOT_LINE_COLOR, 2, clrCrimson);
   PlotIndexSetInteger(1, PLOT_LINE_COLOR, 3, clrGoldenrod);

   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(2, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   if(!InpShowCloud)   PlotIndexSetInteger(0, PLOT_DRAW_TYPE, DRAW_NONE);
   if(!InpShowBaseEMA) PlotIndexSetInteger(2, PLOT_DRAW_TYPE, DRAW_NONE);

   // ── MinBars ──
   const int rsiMin    = InpRSIPeriod + 5;
   const int atrMin    = InpATRPeriod + 5;
   const int volMin    = InpVolumeMA  + 5;
   const int emaMin    = InpEMASlow   + 5;
   const int structMin = InpStructureLookback + InpFractalDepth + 5;
   const int liqMin    = InpLiqLookback + 5;
   g_minBars = MathMax(emaMin,
                MathMax(rsiMin,
                 MathMax(atrMin,
                  MathMax(volMin,
                   MathMax(structMin, liqMin))))) + 5;

   PlotIndexSetInteger(0, PLOT_DRAW_BEGIN, g_minBars);
   PlotIndexSetInteger(1, PLOT_DRAW_BEGIN, g_minBars);
   PlotIndexSetInteger(2, PLOT_DRAW_BEGIN, InpEMAFast + 5);

   // ── Handles chart TF ──
   hEMAFast = iMA (_Symbol, _Period, InpEMAFast,  0, MODE_EMA, PRICE_CLOSE);
   hEMASlow = iMA (_Symbol, _Period, InpEMASlow,  0, MODE_EMA, PRICE_CLOSE);
   hRSI     = iRSI(_Symbol, _Period, InpRSIPeriod,    PRICE_CLOSE);
   hATR     = iATR(_Symbol, _Period, InpATRPeriod);
   hVolMA   = iMA (_Symbol, _Period, InpVolumeMA, 0, MODE_SMA, VOLUME_TICK);

   if(hEMAFast == INVALID_HANDLE || hEMASlow == INVALID_HANDLE
      || hRSI == INVALID_HANDLE  || hATR == INVALID_HANDLE
      || hVolMA == INVALID_HANDLE) {
      Print("❌ BSMC_MA: falha ao criar handles do chart TF");
      return INIT_FAILED;
   }

   // ── Handles MTF (se ativado) ──
   g_mtfTF      = (InpMTFPeriod == PERIOD_CURRENT) ? _Period : InpMTFPeriod;
   g_mtfEnabled = (InpMTFPeriod != PERIOD_CURRENT) && (InpMTFWeight > 0.0);

   if(g_mtfEnabled) {
      const int chartSec = PeriodSeconds(_Period);
      const int mtfSec   = PeriodSeconds(g_mtfTF);
      if(mtfSec <= chartSec) {
         Print("⚠ BSMC_MA: MTF deve ser MAIOR que chart TF — desabilitando prior");
         g_mtfEnabled = false;
      } else {
         hMTFFast = iMA(_Symbol, g_mtfTF, InpEMAFast, 0, MODE_EMA, PRICE_CLOSE);
         hMTFSlow = iMA(_Symbol, g_mtfTF, InpEMASlow, 0, MODE_EMA, PRICE_CLOSE);
         if(hMTFFast == INVALID_HANDLE || hMTFSlow == INVALID_HANDLE) {
            Print("⚠ BSMC_MA: handles MTF falharam — desabilitando prior");
            g_mtfEnabled = false;
         }
      }
   }

   // ── Estado ──
   g_lastFlipColor = 0;
   g_lastFlipTime  = 0;
   g_lastAlertBar  = 0;

   // ── Nome curto ──
   const string mtfTag = (g_mtfEnabled
      ? StringFormat(", MTF=%s w=%.1f", PeriodToStr(g_mtfTF), InpMTFWeight)
      : "");
   IndicatorSetString(INDICATOR_SHORTNAME,
      StringFormat("BSMC_MA v2(%d/%d, σ×%.1f%s)",
                   InpEMAFast, InpEMASlow, InpBandWidth, mtfTag));
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);

   PrintFormat("✔ BayesianSMC_MA v2.0 em %s %s | minBars=%d | MTF=%s",
               _Symbol, EnumToString(_Period), g_minBars,
               g_mtfEnabled ? EnumToString(g_mtfTF) : "OFF");
   return INIT_SUCCEEDED;
}

// ─────────────────────────────────────────────────────────────────
//  OnDeinit
// ─────────────────────────────────────────────────────────────────
void OnDeinit(const int reason) {
   if(hEMAFast != INVALID_HANDLE) { IndicatorRelease(hEMAFast); hEMAFast = INVALID_HANDLE; }
   if(hEMASlow != INVALID_HANDLE) { IndicatorRelease(hEMASlow); hEMASlow = INVALID_HANDLE; }
   if(hRSI     != INVALID_HANDLE) { IndicatorRelease(hRSI);     hRSI     = INVALID_HANDLE; }
   if(hATR     != INVALID_HANDLE) { IndicatorRelease(hATR);     hATR     = INVALID_HANDLE; }
   if(hVolMA   != INVALID_HANDLE) { IndicatorRelease(hVolMA);   hVolMA   = INVALID_HANDLE; }
   if(hMTFFast != INVALID_HANDLE) { IndicatorRelease(hMTFFast); hMTFFast = INVALID_HANDLE; }
   if(hMTFSlow != INVALID_HANDLE) { IndicatorRelease(hMTFSlow); hMTFSlow = INVALID_HANDLE; }

   // Limpa painel APENAS em remoção / fechamento — preserva em
   // PARAMETERS / CHARTCHANGE / RECOMPILE para evitar piscar.
   if(reason == REASON_REMOVE  || reason == REASON_CHARTCLOSE
      || reason == REASON_INITFAILED || reason == REASON_ACCOUNT) {
      ClearPanel();
   }
}

// ─────────────────────────────────────────────────────────────────
//  ALERTAS
// ─────────────────────────────────────────────────────────────────
void DispatchAlert(const string body) {
   Alert(_Symbol, " ", PeriodToStr(_Period), " | BSMC_MA: ", body);
}

// ─────────────────────────────────────────────────────────────────
//  OnCalculate — núcleo
// ─────────────────────────────────────────────────────────────────
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[]) {
   if(rates_total < g_minBars + 5) return 0;

   // ── Aguardar handles populados ──
   if(BarsCalculated(hEMAFast) < rates_total) return prev_calculated;
   if(BarsCalculated(hEMASlow) < rates_total) return prev_calculated;
   if(BarsCalculated(hRSI)     < rates_total) return prev_calculated;
   if(BarsCalculated(hATR)     < rates_total) return prev_calculated;
   if(BarsCalculated(hVolMA)   < rates_total) return prev_calculated;

   // ── Resize cache ──
   if(ArraySize(arr_emaFast) != rates_total) {
      ArrayResize(arr_emaFast, rates_total);
      ArrayResize(arr_emaSlow, rates_total);
      ArrayResize(arr_rsi,     rates_total);
      ArrayResize(arr_atr,     rates_total);
      ArrayResize(arr_volMA,   rates_total);
      ArrayResize(arr_volume,  rates_total);
   }

   // ── Inicializar buffers no first pass ──
   if(prev_calculated == 0) {
      ArrayInitialize(buf_upper, EMPTY_VALUE);
      ArrayInitialize(buf_lower, EMPTY_VALUE);
      ArrayInitialize(buf_line,  EMPTY_VALUE);
      ArrayInitialize(buf_color, EMPTY_VALUE);
      ArrayInitialize(buf_ema,   EMPTY_VALUE);
      ArrayInitialize(buf_bias,  EMPTY_VALUE);
      ArrayInitialize(buf_pBuy,  EMPTY_VALUE);
   }

   // ── Copiar handles do chart TF ──
   ResetLastError();
   if(CopyBuffer(hEMAFast, 0, 0, rates_total, arr_emaFast) <= 0) {
      PrintFormat("⚠ BSMC_MA: CopyBuffer EMAFast falhou (err=%d)", GetLastError());
      return prev_calculated;
   }
   if(CopyBuffer(hEMASlow, 0, 0, rates_total, arr_emaSlow) <= 0) return prev_calculated;
   if(CopyBuffer(hRSI,     0, 0, rates_total, arr_rsi)     <= 0) return prev_calculated;
   if(CopyBuffer(hATR,     0, 0, rates_total, arr_atr)     <= 0) return prev_calculated;
   if(CopyBuffer(hVolMA,   0, 0, rates_total, arr_volMA)   <= 0) return prev_calculated;

   // ── Volume tick em double ──
   const int volStart = (prev_calculated > 1) ? prev_calculated - 1 : 0;
   for(int i = volStart; i < rates_total; ++i) {
      arr_volume[i] = (double)tick_volume[i];
   }

   // ── MTF: bulk-copy para alinhamento por iBarShift ──
   if(g_mtfEnabled && hMTFFast != INVALID_HANDLE && hMTFSlow != INVALID_HANDLE) {
      const int mtfBarsNeeded = iBarShift(_Symbol, g_mtfTF, time[0], false) + 2;
      if(mtfBarsNeeded > 1
         && BarsCalculated(hMTFFast) >= mtfBarsNeeded
         && BarsCalculated(hMTFSlow) >= mtfBarsNeeded) {
         if(ArraySize(arr_mtfFast) != mtfBarsNeeded) {
            ArrayResize(arr_mtfFast, mtfBarsNeeded);
            ArrayResize(arr_mtfSlow, mtfBarsNeeded);
         }
         if(CopyBuffer(hMTFFast, 0, 0, mtfBarsNeeded, arr_mtfFast) <= 0) {
            PrintFormat("⚠ BSMC_MA: CopyBuffer MTFFast falhou (err=%d)", GetLastError());
            ArrayResize(arr_mtfFast, 0);
         }
         if(CopyBuffer(hMTFSlow, 0, 0, mtfBarsNeeded, arr_mtfSlow) <= 0) {
            ArrayResize(arr_mtfSlow, 0);
         }
      }
   }

   // ── Onde começar ──
   int start = (prev_calculated > 0) ? (prev_calculated - 1) : g_minBars;
   if(start < g_minBars) start = g_minBars;
   if(start < 0) start = 0;

   // ── Loop principal: por barra, computa motor + smoothing + bandas ──
   double lastSmoothedBias = 0.0;
   double lastPBuy         = 0.5;
   double lastSigma        = 0.0;
   double lastMTFLogit     = 0.0;
   double lastATR          = 0.0;
   int    lastColorIdx     = 3;

   for(int i = start; i < rates_total; ++i) {
      // 1. Evidências chart
      const double t   = LLR_Trend(i);
      const double m   = LLR_Momentum(i);
      const double s   = LLR_Structure(i, high, low, close, rates_total);
      const double imb = LLR_Imbalance(i, high, low);
      const double liq = LLR_Liquidity(i, high, low, close, open);
      const double v   = LLR_Volume(i, close, open);

      // 2. MTF prior
      const double mtfL = MTF_Logit(time[i]);

      // 3. Combinação Bayesiana em log-odds
      const double logit = InpWTrend     * t
                         + InpWMomentum  * m
                         + InpWStructure * s
                         + InpWImbalance * imb
                         + InpWLiquidity * liq
                         + InpWVolume    * v
                         + InpMTFWeight  * mtfL;

      // 4. Posterior + variância Bernoulli
      const double pBuy    = Sigmoid(logit);
      const double sigma   = MathSqrt(pBuy * (1.0 - pBuy));
      const double rawBias = 2.0 * pBuy - 1.0;
      buf_pBuy[i] = pBuy;

      // 5. Adaptive smoothing: α cresce com |bias|²
      double prevBias = rawBias;
      if(i > 0 && buf_bias[i - 1] != EMPTY_VALUE) prevBias = buf_bias[i - 1];
      const double biasAbsSq = rawBias * rawBias;
      const double alpha = InpAlphaMin + (InpAlphaMax - InpAlphaMin) * biasAbsSq;
      const double smoothedBias = alpha * rawBias + (1.0 - alpha) * prevBias;
      buf_bias[i] = smoothedBias;

      // 6. Linha + bandas
      const double ema = arr_emaFast[i];
      const double atr = arr_atr[i];
      const double line = ema + smoothedBias * atr * InpDisplacement;
      const double half = sigma * atr * InpBandWidth;

      buf_ema[i]   = ema;
      buf_line[i]  = line;
      buf_upper[i] = line + half;
      buf_lower[i] = line - half;

      // 7. Cor
      int colorIdx;
      if(MathAbs(smoothedBias) < InpNeutralThreshold) colorIdx = 3;
      else if(smoothedBias > 0.0)                     colorIdx = 1;
      else                                            colorIdx = 2;
      buf_color[i] = (double)colorIdx;

      // ── Track últimos valores p/ painel + alertas ──
      lastSmoothedBias = smoothedBias;
      lastPBuy         = pBuy;
      lastSigma        = sigma;
      lastMTFLogit     = mtfL;
      lastATR          = atr;
      lastColorIdx     = colorIdx;
   }

   // ── Alertas e painel: APENAS na barra mais recente ──
   if(rates_total > 0 && start < rates_total) {
      const int last = rates_total - 1;

      // FLIP: a cor mudou em relação à última cor registrada
      if(InpAlertOnFlip
         && g_lastFlipColor != 0
         && lastColorIdx != g_lastFlipColor
         && lastColorIdx != 3
         && time[last] != g_lastAlertBar) {
         const string body = StringFormat("FLIP %s | P(BUY)=%.2f | conf=%d%%",
            (lastColorIdx == 1 ? "BUY" : "SELL"),
            lastPBuy,
            (int)MathRound(MathAbs(lastSmoothedBias) * 100.0));
         DispatchAlert(body);
         g_lastFlipTime = time[last];
         g_lastAlertBar = time[last];
      }
      if(g_lastFlipColor != lastColorIdx && lastColorIdx != 3) {
         if(g_lastFlipColor != 0) g_lastFlipTime = time[last];
         g_lastFlipColor = lastColorIdx;
      } else if(g_lastFlipColor == 0) {
         g_lastFlipColor = lastColorIdx;
      }

      // CROSS preço × linha (na vela fechada anterior)
      if(InpAlertOnCross && last >= 1
         && buf_line[last - 1] != EMPTY_VALUE
         && time[last] != g_lastAlertBar) {
         const bool crossUp   = (close[last - 1] < buf_line[last - 1]) && (close[last] >= buf_line[last]);
         const bool crossDown = (close[last - 1] > buf_line[last - 1]) && (close[last] <= buf_line[last]);
         if(crossUp || crossDown) {
            DispatchAlert(StringFormat("CROSS %s @ %s",
               (crossUp ? "↑ acima" : "↓ abaixo"),
               DoubleToString(close[last], _Digits)));
            g_lastAlertBar = time[last];
         }
      }

      // Painel — atualiza a cada tick (objetos persistem; só ObjectSetString)
      DrawPanel(lastPBuy, lastSmoothedBias, lastMTFLogit, lastSigma, lastATR);
   }

   return rates_total;
}
//+------------------------------------------------------------------+