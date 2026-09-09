//+------------------------------------------------------------------+
//|                                             ExportHistoryTSV.mq5 |
//|  口座の取引履歴を「本物のマジックナンバー付き」でTSV出力する      |
//+------------------------------------------------------------------+
//
//  ExportHistoryTSV.mq4 のMT5版。出力する列は完全に同じなので、
//  MT_Trade_Analyzer.html は両方を同じように読める。
//
//  使い方
//    1. このファイルを <データフォルダ>/MQL5/Scripts/ に置く
//       （MT5のメニュー: ファイル → データフォルダを開く）
//    2. MetaEditor で開いてコンパイル（F7）
//    3. ナビゲータの「スクリプト」から任意のチャートにドラッグ
//    4. 出力先は <データフォルダ>/MQL5/Files/ に作られる
//       InpSubFolder を指定すると、その下のサブフォルダに作られる。
//       Google Drive に自動で上げたい場合は、そのフォルダを
//       Drive デスクトップ版の同期対象に追加する
//    5. そのTSVを MT_Trade_Analyzer.html にドロップする
//
//  MT4版との違い
//    MT5の履歴は「ディール（約定）」単位で記録される。
//    ポジションを閉じた側のディール（DEAL_ENTRY_OUT）に確定損益が乗るので
//    そこを1取引として出力する。
//
//    ★ただしEAが指定したマジックナンバーとコメントは
//      「エントリー側のディール」にしか乗らない。決済側は
//        - コメント: 空、またはSL/TP決済なら "sl" "tp" "so" など端末が入れる文字列
//        - マジック: SL/TP決済だと 0（SL/TP注文はEAではなくサーバーが出すため）
//      になる。決済側だけを見るとEA名が取れず、SL/TP決済のマジックが全部0になる。
//      そこで建玉時刻・建値に加えてマジックとコメントも
//      同じ DEAL_POSITION_ID を持つ DEAL_ENTRY_IN 側から引いている。
//      IN側が空/0のときだけ決済側の値をそのまま使う。
//
//    ネッティング口座で部分決済や途転（DEAL_ENTRY_INOUT）が混ざる場合は
//    1ポジションが複数行に分かれることがある。ヘッジング口座なら
//    1ポジション=1行になる。
//
//  出力列（タブ区切り）
//    ticket / open time / close time / type / symbol / lots /
//    open price / close price / magic / commission / swap /
//    profit / net / comment / close comment
//
//    ticket        = DEAL_POSITION_ID（ポジション番号）
//    magic         = IN側の DEAL_MAGIC（無ければ決済側）
//    comment       = IN側の DEAL_COMMENT（EAが書いた本来のコメント）
//    close comment = 決済側の DEAL_COMMENT（"sl" "tp" "so" など決済理由）
//    profit        = DEAL_PROFIT   … HTMLレポートのProfit列と同じ意味
//    net           = profit + commission + swap + fee
//+------------------------------------------------------------------+
#property copyright "MT4/MT5 Trade Analyzer"
#property version   "1.00"
#property script_show_inputs

input string   InpFileName       = "";     // 出力ファイル名（空欄=自動命名）
input string   InpSubFolder      = "";     // 出力先サブフォルダ（空欄=Files直下）
input datetime InpFrom           = 0;      // この決済日時以降のみ（0=全期間）
input datetime InpTo             = 0;      // この決済日時以前のみ（0=全期間）
input bool     InpIncludeBalance = false;  // 入出金(balance/credit)も出力する
input bool     InpIncludeOpen    = false;  // 未決済ポジションも出力する

#define TAB "\t"

//+------------------------------------------------------------------+
//| サブフォルダ名の検証。使えない指定なら "!" を返す。               |
//| MQL のファイル操作は MQL5/Files の外に出られないので、          |
//| ドライブ文字や上位への移動 (..) は受け付けない。                  |
//+------------------------------------------------------------------+
string NormalizeSubFolder(string v)
  {
   StringTrimLeft(v);
   StringTrimRight(v);
   if(StringLen(v) == 0)
      return("");

   StringReplace(v, "/", "\\");          // スラッシュ区切りも許す

   //--- 前後の区切り文字を落とす
   while(StringLen(v) > 0 && StringSubstr(v, 0, 1) == "\\")
      v = StringSubstr(v, 1);
   while(StringLen(v) > 0 && StringSubstr(v, StringLen(v) - 1, 1) == "\\")
      v = StringSubstr(v, 0, StringLen(v) - 1);
   if(StringLen(v) == 0)
      return("");

   //--- ドライブ指定 (C: など) と上位への移動は不可
   if(StringFind(v, ":") >= 0)
      return("!");
   if(StringFind(v, "..") >= 0)
      return("!");

   return(v);
  }

//--- IN側ディールの索引（position_id -> 建玉情報）
//
//  ★MT5の要注意点
//    EAが指定したマジックナンバーとコメントは「エントリー側のディール」に乗る。
//    決済側(DEAL_ENTRY_OUT)は
//      - コメント: 空、またはSL/TP決済なら "sl" "tp" "so" など端末が入れる文字列
//      - マジック: SL/TP決済だと 0（SL/TP注文はEAではなくサーバーが出すため）
//    になる。したがってマジックもコメントもIN側から引く必要がある。
long     g_inPos[];
datetime g_inTime[];
double   g_inPrice[];
long     g_inType[];
long     g_inMagic[];
string   g_inComment[];

//+------------------------------------------------------------------+
//| ポジション種別を文字列に                                          |
//+------------------------------------------------------------------+
string PosTypeName(const long dealType)
  {
   if(dealType == DEAL_TYPE_BUY)
      return("buy");
   if(dealType == DEAL_TYPE_SELL)
      return("sell");
   if(dealType == DEAL_TYPE_BALANCE)
      return("balance");
   if(dealType == DEAL_TYPE_CREDIT)
      return("credit");
   if(dealType == DEAL_TYPE_CORRECTION)
      return("correction");
   if(dealType == DEAL_TYPE_BONUS)
      return("bonus");
   if(dealType == DEAL_TYPE_COMMISSION)
      return("commission");
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
//| 小数桁数（銘柄が取得できないときは5桁）                           |
//+------------------------------------------------------------------+
int SymDigits(const string sym)
  {
   long d = 0;
   if(StringLen(sym) > 0 && SymbolInfoInteger(sym, SYMBOL_DIGITS, d) && d > 0)
      return((int)d);
   return(5);
  }

//+------------------------------------------------------------------+
//| IN側ディールを索引に登録                                          |
//+------------------------------------------------------------------+
void IndexInDeal(const long posId, const datetime t, const double price,
                 const long type, const long magic, const string comment)
  {
   int n = ArraySize(g_inPos);
   ArrayResize(g_inPos,     n + 1);
   ArrayResize(g_inTime,    n + 1);
   ArrayResize(g_inPrice,   n + 1);
   ArrayResize(g_inType,    n + 1);
   ArrayResize(g_inMagic,   n + 1);
   ArrayResize(g_inComment, n + 1);
   g_inPos[n]     = posId;
   g_inTime[n]    = t;
   g_inPrice[n]   = price;
   g_inType[n]    = type;
   g_inMagic[n]   = magic;
   g_inComment[n] = comment;
  }

//+------------------------------------------------------------------+
//| position_id から索引位置を引く（見つからなければ -1）             |
//+------------------------------------------------------------------+
int FindInDeal(const long posId)
  {
   for(int i = ArraySize(g_inPos) - 1; i >= 0; i--)
      if(g_inPos[i] == posId)
         return(i);
   return(-1);
  }

//+------------------------------------------------------------------+
void OnStart()
  {
   if(!HistorySelect(0, TimeCurrent()))
     {
      Alert("履歴の取得に失敗しました");
      return;
     }

   string fname = InpFileName;
   if(StringLen(fname) == 0)
     {
      string d = TimeToString(TimeCurrent(), TIME_DATE);   // 2026.09.04
      StringReplace(d, ".", "");
      fname = "history_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN))
              + "_" + d + ".tsv";
     }

   /* サブフォルダ指定。MQL は MQL5/Files の中しか触れないので、
      絶対パスや上位への移動は弾く。Google Drive に自動で上げたい場合は、
      ここで指定したフォルダを Drive 側の同期対象に追加する。 */
   string sub = NormalizeSubFolder(InpSubFolder);
   if(sub == "!")
     {
      Alert("出力先サブフォルダが不正です: ", InpSubFolder,
            " / ドライブ文字や .. は使えません（MQL5/Files の下だけ）");
      return;
     }
   string path = fname;
   if(StringLen(sub) > 0)
     {
      /* すでに在る場合もエラーを返す環境があるため、失敗しても続行して
         FileOpen の結果で判断する */
      if(!FolderCreate(sub))
         Print("FolderCreate note: ", sub, " error=", GetLastError());
      path = sub + "\\" + fname;
     }

   int h = FileOpen(path, FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(h == INVALID_HANDLE)
     {
      int err = GetLastError();
      Print("FileOpen failed: ", path, " error=", err);
      Alert("ファイルを開けませんでした: ", path, " (error ", err, ")");
      return;
     }

   FileWrite(h,
             "ticket"      + TAB + "open time"   + TAB + "close time" + TAB +
             "type"        + TAB + "symbol"      + TAB + "lots"       + TAB +
             "open price"  + TAB + "close price" + TAB + "magic"      + TAB +
             "commission"  + TAB + "swap"        + TAB + "profit"     + TAB +
             "net"         + TAB + "comment"     + TAB + "close comment");

   int total = HistoryDealsTotal();

   // ---- 1周目: エントリー側を索引化 ----
   ArrayResize(g_inPos, 0);
   ArrayResize(g_inTime, 0);
   ArrayResize(g_inPrice, 0);
   ArrayResize(g_inType, 0);
   ArrayResize(g_inMagic, 0);
   ArrayResize(g_inComment, 0);
   for(int i = 0; i < total; i++)
     {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0)
         continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_IN)
         continue;
      IndexInDeal(HistoryDealGetInteger(ticket, DEAL_POSITION_ID),
                  (datetime)HistoryDealGetInteger(ticket, DEAL_TIME),
                  HistoryDealGetDouble(ticket, DEAL_PRICE),
                  HistoryDealGetInteger(ticket, DEAL_TYPE),
                  HistoryDealGetInteger(ticket, DEAL_MAGIC),
                  HistoryDealGetString(ticket, DEAL_COMMENT));
     }

   // ---- 2周目: 決済側を出力 ----
   int closedCount  = 0;
   int balanceCount = 0;
   int skippedCount = 0;

   for(int i = 0; i < total; i++)
     {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0)
         continue;

      long     dealType = HistoryDealGetInteger(ticket, DEAL_TYPE);
      long     entry    = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      datetime dealTime = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);

      bool isBalance = (dealType != DEAL_TYPE_BUY && dealType != DEAL_TYPE_SELL);
      if(isBalance)
        {
         if(!InpIncludeBalance)
           {
            skippedCount++;
            continue;
           }
        }
      else
        {
         // 決済側のディールだけを1取引として扱う
         if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT
            && entry != DEAL_ENTRY_OUT_BY)
           {
            skippedCount++;
            continue;
           }
        }

      if(InpFrom > 0 && dealTime < InpFrom)
        {
         skippedCount++;
         continue;
        }
      if(InpTo > 0 && dealTime > InpTo)
        {
         skippedCount++;
         continue;
        }

      long   posId  = HistoryDealGetInteger(ticket, DEAL_POSITION_ID);
      string sym    = HistoryDealGetString(ticket, DEAL_SYMBOL);
      int    digits = SymDigits(sym);

      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
      double comm   = HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      double swap   = HistoryDealGetDouble(ticket, DEAL_SWAP);
      double fee    = HistoryDealGetDouble(ticket, DEAL_FEE);

      // 決済側のコメントとマジック（SL/TP決済だと "sl"/"tp"、magicは0になる）
      string closeComment = Clean(HistoryDealGetString(ticket, DEAL_COMMENT));
      long   magic        = HistoryDealGetInteger(ticket, DEAL_MAGIC);
      string comment      = closeComment;

      // エントリー情報を補完。見つからない場合は決済側の逆向きを採用する
      string   typeStr   = "";
      string   openTime  = "";
      string   openPrice = "";
      int      idx       = (posId != 0 ? FindInDeal(posId) : -1);
      if(idx >= 0)
        {
         typeStr   = PosTypeName(g_inType[idx]);
         openTime  = TimeToString(g_inTime[idx], TIME_DATE|TIME_SECONDS);
         openPrice = DoubleToString(g_inPrice[idx], digits);

         // EA名とマジックはIN側が本物。IN側が空/0のときだけ決済側を使う
         string inComment = Clean(g_inComment[idx]);
         if(StringLen(inComment) > 0)
            comment = inComment;
         if(g_inMagic[idx] != 0)
            magic = g_inMagic[idx];
        }
      else
        {
         if(isBalance)
            typeStr = PosTypeName(dealType);
         else                       // 決済側は建玉と逆向きなので反転させる
            typeStr = (dealType == DEAL_TYPE_SELL) ? "buy" : "sell";
        }

      FileWrite(h,
                IntegerToString(posId != 0 ? posId : (long)ticket)          + TAB +
                openTime                                                   + TAB +
                TimeToString(dealTime, TIME_DATE|TIME_SECONDS)             + TAB +
                typeStr                                                    + TAB +
                sym                                                        + TAB +
                DoubleToString(HistoryDealGetDouble(ticket, DEAL_VOLUME), 2) + TAB +
                openPrice                                                  + TAB +
                DoubleToString(HistoryDealGetDouble(ticket, DEAL_PRICE), digits) + TAB +
                IntegerToString(magic)                                     + TAB +
                DoubleToString(comm, 2)                                    + TAB +
                DoubleToString(swap, 2)                                    + TAB +
                DoubleToString(profit, 2)                                  + TAB +
                DoubleToString(profit + comm + swap + fee, 2)              + TAB +
                comment                                                    + TAB +
                closeComment);

      if(isBalance)
         balanceCount++;
      else
         closedCount++;
     }

   // ---- 未決済（任意）----
   int openCount = 0;
   if(InpIncludeOpen)
     {
      int live = PositionsTotal();
      for(int p = 0; p < live; p++)
        {
         // PositionGetSymbol は銘柄名を返し、同時にそのポジションを選択する
         string sym = PositionGetSymbol(p);
         if(StringLen(sym) == 0)
            continue;
         int digits = SymDigits(sym);
         double profit = PositionGetDouble(POSITION_PROFIT);
         double swap   = PositionGetDouble(POSITION_SWAP);

         FileWrite(h,
                   IntegerToString(PositionGetInteger(POSITION_IDENTIFIER))   + TAB +
                   TimeToString((datetime)PositionGetInteger(POSITION_TIME),
                                TIME_DATE|TIME_SECONDS)                       + TAB +
                   ""                                                         + TAB +
                   (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY
                    ? "buy" : "sell")                                         + TAB +
                   sym                                                        + TAB +
                   DoubleToString(PositionGetDouble(POSITION_VOLUME), 2)      + TAB +
                   DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), digits) + TAB +
                   DoubleToString(PositionGetDouble(POSITION_PRICE_CURRENT), digits) + TAB +
                   IntegerToString(PositionGetInteger(POSITION_MAGIC))        + TAB +
                   "0.00"                                                     + TAB +
                   DoubleToString(swap, 2)                                    + TAB +
                   DoubleToString(profit, 2)                                  + TAB +
                   DoubleToString(profit + swap, 2)                           + TAB +
                   Clean(PositionGetString(POSITION_COMMENT))                 + TAB +
                   "");
         openCount++;
        }
     }

   FileClose(h);

   string msg = "書き出しました: MQL5/Files/" + path + "\n"
                + "決済 " + IntegerToString(closedCount) + " 件"
                + " / 入出金 " + IntegerToString(balanceCount) + " 件"
                + " / 未決済 " + IntegerToString(openCount) + " 件"
                + " / 除外 " + IntegerToString(skippedCount) + " 件";

   if(total == 0)
      msg = msg + "\n\n履歴が0件です。ターミナルの履歴タブで期間を"
                + "「すべて」にしてから実行してください。";

   Print(msg);
   Alert(msg);
  }
//+------------------------------------------------------------------+
