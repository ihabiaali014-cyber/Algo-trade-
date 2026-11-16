# ORB New York : EA conforme FTMO

Fichiers :
- EA MetaTrader 5 : [`mt5/ORB_NY_FTMO.mq5`](../mt5/ORB_NY_FTMO.mq5)
- Stratégie TradingView (même logique, pour backtester) : [`tradingview/orb_ny_ftmo_strategy.pine`](../tradingview/orb_ny_ftmo_strategy.pine)

## Pourquoi cette stratégie

L'**Opening Range Breakout (ORB)** sur l'ouverture cash de New York est l'une des rares stratégies
intraday étudiées publiquement sur de longues périodes :
- Toby Crabel, *Day Trading with Short Term Price Patterns and Opening Range Breakout* (1990).
- Zarattini & Aziz (2023), *Can Day Trading Really Be Profitable?* (SSRN) : ORB 5 minutes sur QQQ
  de 2016 à 2023, rentable après frais, avec un comportement très différent du buy & hold.

L'idée de fond : les 15 premières minutes concentrent les ordres de l'ouverture cash. Quand le prix
sort de ce range dans le sens de la tendance, la journée devient souvent une **journée de tendance**.
Le gain vient de quelques grosses journées (TP à 3R) qui paient beaucoup de petites pertes de 1R.
Attends-toi à un **winrate autour de 35 à 45 %**. C'est normal pour ce type de stratégie.

> Aucune stratégie n'est garantie. Les études ci-dessus portent sur des variantes proches, pas sur ce code
> exact. **C'est ton backtest qui doit valider (ou invalider) l'edge** avant de mettre un challenge en jeu.

## Règles (version long, le short est le miroir)

| Étape | Règle |
|---|---|
| Actif | US100 / NAS100 (CFD FTMO : `US100.cash`), ou MNQ / NQ en futures |
| Opening range | High et low de **9h30 à 9h45, heure de New York** |
| Filtre de taille | Range entre **8 % et 50 % de l'ATR(14) journalier** d'hier. Sinon, pas de trade ce jour-là |
| Filtre de tendance | Long seulement si la **clôture d'hier > EMA 20 journalière** (short si en dessous) |
| Entrée | Une bougie **M5 clôture au-dessus du high du range** (première cassure). Entrée au marché, entre 9h45 et **12h00 NY** |
| Stop loss | **Low du range** − 2 % de l'ATR journalier |
| Take profit | **3R** |
| Sortie forcée | **15h50 NY** si ni SL ni TP touché |
| Fréquence | **1 trade max par jour** |
| Risque | **0,5 % du solde par trade** |

Correspondance horaire (serveur FTMO, GMT+2/+3) : en temps normal, 9h30 NY = **16h30 serveur**.
L'EA gère automatiquement les semaines de décalage d'heure d'été entre l'Europe et les États-Unis
(mars et fin octobre / début novembre), où 9h30 NY = 15h30 serveur.

## Conformité FTMO

| Règle FTMO | Comment l'EA la respecte |
|---|---|
| Max Daily Loss 5 % | Coupure interne à **4 %** du solde initial, mesurée depuis le solde de début de journée (minuit serveur = minuit CE(S)T), **flottant inclus**, vérifiée à chaque tick. Positions fermées, plus de trade jusqu'au lendemain |
| Max Loss 10 % | Coupure interne à **8 %** (plancher statique). L'EA s'arrête définitivement |
| Contrôle avant chaque ordre | Si le SL du trade pouvait faire passer sous un des deux planchers, le trade n'est pas pris |
| News (compte FTMO standard) | Pas d'entrée 5 min avant / après une news USD haute importance (calendrier MT5, en live uniquement) |
| Pas d'overnight ni de week-end | Clôture forcée à 15h50 NY chaque jour |
| Pratiques interdites | Pas de HFT, de tick scalping, de martingale, de grid, d'arbitrage de latence ni de hedge entre comptes. 1 ordre par jour, logique sur bougies M5 clôturées |
| Minimum 4 jours de trading | Atteint naturellement (≈ 1 trade par jour éligible) |
| Objectif de profit | Option `Arrêter après +X %` (mettre 10 en phase 1, 5 en phase 2). L'EA ferme et s'arrête une fois l'objectif atteint |

Avec 0,5 % de risque et 1 trade par jour, une journée perd au pire environ 0,5 % (plus le slippage) :
la coupure journalière ne sert que de filet en cas de gap ou de problème d'exécution. Pour toucher la
coupure de perte max à 8 %, il faudrait environ **17 pertes de suite sans aucun gain**.

Les arrêts (jour et définitif) sont stockés dans les variables globales du terminal (touche **F3**,
préfixe `ORB_<numéro de compte>_<magic>_`). Pour réarmer l'EA sur un nouveau compte, supprime ces variables
ou change le magic number.

## Installation MT5

1. MT5 → *Fichier → Ouvrir le dossier des données* → `MQL5/Experts/` → copie `ORB_NY_FTMO.mq5`.
2. Ouvre-le dans **MetaEditor** et compile (F7).
3. Ouvre un graphique **US100.cash** (n'importe quelle UT, la logique utilise M1, M5 et D1).
4. Glisse l'EA dessus, active *Algo Trading*.
5. Mets **`Solde initial du compte`** = taille du challenge (ex. `100000`). Ne laisse pas 0 si le compte a
   déjà bougé.

## Backtest MT5 (Strategy Tester)

- Symbole `US100.cash`, modèle **« Every tick based on real ticks »**, dépôt = taille du challenge.
- Période : **au moins 3 à 5 ans** (ex. 2020 → aujourd'hui), pour couvrir des régimes différents (2022 baissier, 2023-2024 haussiers).
- Le filtre news est inactif dans le testeur (le calendrier MT5 n'y est pas disponible).
- Ce qu'il faut regarder : profit factor > 1,3 ; drawdown max < 8 % ; pire journée > −2 % ;
  résultat positif sur chaque année prise séparément.
- **Évite la sur-optimisation** : optimise au maximum 2 paramètres (ex. `InpTP_RR`, `InpORMinutes`) sur
  2020-2023, puis vérifie sur 2024-2026 sans rien toucher (out-of-sample).

## Backtest TradingView

1. Graphique **5 minutes** sur `MNQ1!` (futures, `Pas de quantité` = 1) ou un CFD Nasdaq (`Pas de quantité` = 0.01).
2. Éditeur Pine → nouveau script → colle `orb_ny_ftmo_strategy.pine` → *Ajouter au graphique*.
3. Onglet **Strategy Tester** pour la courbe et la liste des trades. Le tableau en haut à droite indique
   le drawdown max, la pire journée et si les limites FTMO auraient été respectées.
4. Avec MNQ et 100 000 $ de capital, 0,5 % de risque = 500 $, soit environ 2 à 4 contrats selon la taille du range.

## Backtest FX Replay (manuel)

FX Replay ne fait pas tourner d'EA ni de script Pine : on y rejoue la stratégie à la main. Checklist pour
chaque journée rejouée (graphique NAS100 ou US100, UT 5 minutes, fuseau **New York** dans les réglages) :

1. **Avant 9h30** : note la clôture d'hier et l'EMA 20 journalière (ajoute l'indicateur EMA 20 sur l'UT D1).
   Au-dessus = longs seulement, en dessous = shorts seulement. Note aussi l'ATR 14 journalier.
2. **9h30 → 9h45** : trace le high et le low des 3 bougies M5 (= opening range).
3. Calcule `taille du range ÷ ATR`. Si c'est **< 0,08 ou > 0,50**, pas de trade aujourd'hui.
4. **9h45 → 12h00** : attends la **clôture** d'une bougie M5 au-delà du range, dans le sens autorisé.
   Ignore une cassure dans le mauvais sens (pas de trade inverse).
5. Entrée à l'ouverture de la bougie suivante. SL = autre côté du range ± 2 % de l'ATR. TP = 3 × la distance du SL.
6. Taille : risque de 0,5 % du solde (le calculateur de position de FX Replay le fait).
7. Toujours en position à **15h50** : sortie au marché.
8. Un seul trade par jour, puis journée suivante.

Rejoue au moins **150 à 200 journées** pour avoir une statistique utile. Note chaque trade (date, sens,
R obtenu) dans un tableur pour comparer avec le backtest MT5 / TradingView.

## Paramètres principaux de l'EA

| Paramètre | Défaut | Rôle |
|---|---|---|
| `InpRiskPct` | 0.5 | Risque par trade, en % du solde |
| `InpDailyLossLimit` / `InpMaxLossLimit` | 4 / 8 | Coupures internes, sous les limites FTMO (5 / 10) |
| `InpProfitTargetPct` | 0 | Arrête l'EA une fois l'objectif atteint (10 en phase 1, 5 en phase 2) |
| `InpServerTZ` | EU DST | Fuseau du serveur. FTMO = GMT+2/+3 avec heure d'été européenne |
| `InpORMinutes` | 15 | Durée de l'opening range |
| `InpLastEntryNY` / `InpCloseNY` | 1200 / 1550 | Dernière entrée et clôture forcée (heure NY) |
| `InpTrendFilter` / `InpTrendEMA` | oui / 20 | Filtre de tendance journalier |
| `InpMinRangeATR` / `InpMaxRangeATR` | 0.08 / 0.50 | Filtre de taille du range |
| `InpSLMode` | Opposé | SL de l'autre côté du range, ou au milieu (SL plus serré, plus de stops) |
| `InpTP_RR` | 3.0 | TP en multiple du risque (0 = sortie à 15h50 seulement) |
| `InpBE_RR` | 0 | Break-even (désactivé : il coupe souvent les journées de tendance) |
| `InpUseNews` | oui | Filtre news USD haute importance (live uniquement) |

## Limites connues

- **Journées écourtées** (veille de Thanksgiving, de Noël, etc.) : le marché cash ferme à 13h00 NY,
  avant la sortie de 15h50. Dans ce cas la position est fermée à la reprise suivante. Le plus simple
  est de désactiver l'EA ces jours-là.
- Les **spreads et commissions** varient d'un broker à l'autre : refais le backtest avec les conditions
  réelles de ton compte FTMO.
- Je n'ai pas pu compiler l'EA ni exécuter le script Pine dans cet environnement (pas de MetaEditor ni de
  TradingView). Si la compilation remonte une erreur, envoie-moi le message exact.
