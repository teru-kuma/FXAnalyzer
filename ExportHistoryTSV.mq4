//+------------------------------------------------------------------+
//|                                             ExportHistoryTSV.mq4 |
//|  口座の取引履歴を「本物のマジックナンバー付き」でTSV出力する      |
//+------------------------------------------------------------------+
//
//  なぜ必要か
//    MT4のHTMLレポート（DetailedStatement.htm）には
//    マジックナンバーの列が存在しない。
//    そのためComment欄から推測するしかなく、コメントにその時のレート
//    （145.612 など）を書くEAでは誤判定が避けられない。
//    このスクリプトは端末から OrderMagicNumber() を直接読むので、
//    推測が一切不要になる。
//
//  使い方
//    1. このファイルを <データフォルダ>/MQL4/Scripts/ に置く
//       （MT4のメニュー: ファイル → データフォルダを開く）
//    2. MetaEditor で開いてコンパイル（F7）
//    3. ナビゲータの「スクリプト」から任意のチャートにドラッグ
//    4. 出力先は <データフォルダ>/MQL4/Files/ に作られる
//    5. そのTSVを MT_Trade_Analyzer.html にドロップする
//
//  ★重要
//    MT4は「口座履歴」タブに読み込まれている範囲しか
//    OrdersHistoryTotal() で参照できない。
//    実行前にターミナルの口座履歴タブを右クリック →「全履歴」を
//    選んでおくこと。期間を絞っていると出力も欠ける。
//
//  出力列（タブ区切り。MT5版と完全に同じ）
//    ticket / open time / close time / type / symbol / lots /
//    open price / close price / magic / commission / swap /
//    profit / net / comment / close comment
//
//    close comment はMT5版との列合わせのため常に空。
//    MT4はコメントが1つしかなく、SL/TP決済でも同じ文字列に
//    [sl] [tp] が付くだけなので分離する必要がない。
//
//    profit = OrderProfit()  … HTMLレポートのProfit列と同じ意味
//    net    = profit + commission + swap  … 手数料込みの実質損益
//    アナライザは "profit" 列を使うのでHTMLレポートと数字が一致する。
//+------------------------------------------------------------------+
#property copyright "MT4/MT5 Trade Analyzer"
#property version   "1.00"
#property strict
#property show_inputs

input string   InpFileName       = "";     // 出力ファイル名（空欄=自動命名）
input datetime InpFrom           = 0;      // この決済日時以降のみ（0=全期間）
input datetime InpTo             = 0;      // この決済日時以前のみ（0=全期間）
input bool     InpIncludeBalance = false;  // 入出金(balance/credit)も出力する
input bool     InpIncludeOpen    = false;  // 未決済ポジションも出力する

#define TAB "\t"

//+------------------------------------------------------------------+
//| 注文種別を文字列に                                                |
//+------------------------------------------------------------------+
string TypeName(const int t)
  {
   switch(t)
     {
      case OP_BUY:       return("buy");
      case OP_SELL:      return("sell");
      case OP_BUYLIMIT:  return("buy limit");
      case OP_SELLLIMIT: return("sell limit");
      case OP_BUYSTOP:   return("buy stop");
      case OP_SELLSTOP:  return("sell stop");
      case 6:            return("balance"); // MQL4に定数が無いので数値で判定
      case 7:            return("credit");
     }
   return("unknown");
  }

//+------------------------------------------------------------------+
//| TSVを壊す文字を空白に置換                                         |
//+------------------------------------------------------------------+
string Clean(string s)
  {
   StringReplace(s, "\t", " ");
   StringReplace(s, "\r", " ");
   StringReplace(s, "\n", " ");
   return(s);
  }

//+------------------------------------------------------------------+
//| 選択中の注文を1行に整形                                           |
//+------------------------------------------------------------------+
string BuildRow()
  {
   string sym    = OrderSymbol();
   int    digits = (int)MarketInfo(sym, MODE_DIGITS);
   if(digits <= 0)
      digits = 5;

   double profit = OrderProfit();
   double comm   = OrderCommission();
   double swap   = OrderSwap();

   string closeTime = "";
   if(OrderCloseTime() > 0)
      closeTime = TimeToString(OrderCloseTime(), TIME_DATE|TIME_SECONDS);

   return(IntegerToString(OrderTicket())                              + TAB +
          TimeToString(OrderOpenTime(), TIME_DATE|TIME_SECONDS)        + TAB +
          closeTime                                                   + TAB +
          TypeName(OrderType())                                       + TAB +
          sym                                                         + TAB +
          DoubleToString(OrderLots(), 2)                              + TAB +
          DoubleToString(OrderOpenPrice(), digits)                    + TAB +
          DoubleToString(OrderClosePrice(), digits)                   + TAB +
          IntegerToString(OrderMagicNumber())                         + TAB +
          DoubleToString(comm, 2)                                     + TAB +
          DoubleToString(swap, 2)                                     + TAB +
          DoubleToString(profit, 2)                                   + TAB +
          DoubleToString(profit + comm + swap, 2)                     + TAB +
          Clean(OrderComment())                                       + TAB +
          "");   // MT4はコメントが1つだけ（[sl]/[tp]は同じ文字列に付く）ので空欄
  }

//+------------------------------------------------------------------+
//| 出力対象か判定（決済済み）                                        |
//+------------------------------------------------------------------+
bool WantHistoryOrder()
  {
   int t = OrderType();

   if(t == 6 || t == 7)                       // balance / credit
      return(InpIncludeBalance);

   if(t != OP_BUY && t != OP_SELL)            // 約定せず削除された指値・逆指値
      return(false);

   datetime ct = OrderCloseTime();
   if(InpFrom > 0 && ct < InpFrom)
      return(false);
   if(InpTo > 0 && ct > InpTo)
      return(false);

   return(true);
  }

//+------------------------------------------------------------------+
void OnStart()
  {
   string fname = InpFileName;
   if(StringLen(fname) == 0)
     {
      string d = TimeToString(TimeCurrent(), TIME_DATE);   // 2026.09.04
      StringReplace(d, ".", "");
      fname = "history_" + IntegerToString(AccountNumber()) + "_" + d + ".tsv";
     }

   int h = FileOpen(fname, FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(h == INVALID_HANDLE)
     {
      int err = GetLastError();
      Print("FileOpen failed: ", fname, " error=", err);
      Alert("ファイルを開けませんでした: ", fname, " (error ", err, ")");
      return;
     }

   FileWrite(h,
             "ticket"      + TAB + "open time"   + TAB + "close time" + TAB +
             "type"        + TAB + "symbol"      + TAB + "lots"       + TAB +
             "open price"  + TAB + "close price" + TAB + "magic"      + TAB +
             "commission"  + TAB + "swap"        + TAB + "profit"     + TAB +
             "net"         + TAB + "comment"     + TAB + "close comment");

   int closedCount  = 0;
   int skippedCount = 0;
   int openCount    = 0;

   // ---- 決済済み ----
   int total = OrdersHistoryTotal();
   for(int i = 0; i < total; i++)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY))
         continue;
      if(!WantHistoryOrder())
        {
         skippedCount++;
         continue;
        }
      FileWrite(h, BuildRow());
      closedCount++;
     }

   // ---- 未決済（任意）----
   if(InpIncludeOpen)
     {
      int live = OrdersTotal();
      for(int j = 0; j < live; j++)
        {
         if(!OrderSelect(j, SELECT_BY_POS, MODE_TRADES))
            continue;
         if(OrderType() != OP_BUY && OrderType() != OP_SELL)
            continue;
         FileWrite(h, BuildRow());
         openCount++;
        }
     }

   FileClose(h);

   string msg = "書き出しました: MQL4/Files/" + fname + "\n"
                + "決済 " + IntegerToString(closedCount) + " 件"
                + " / 未決済 " + IntegerToString(openCount) + " 件"
                + " / 除外 " + IntegerToString(skippedCount) + " 件";

   if(total == 0)
      msg = msg + "\n\n履歴が0件です。口座履歴タブを右クリック →「全履歴」を"
                + "選んでから実行してください。";

   Print(msg);
   Alert(msg);
  }
//+------------------------------------------------------------------+
