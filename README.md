# Algo-trade

## Sweep → FVG HTF → Reversal (v1, indicateur TradingView)

Fichier : [`tradingview/sweep_fvg_reversal.pine`](tradingview/sweep_fvg_reversal.pine)

### Le pattern (version long, le short est le miroir)
1. **Impulsion haussière** qui laisse une **FVG haussière** en 2m, 3m ou 5m.
   La FVG n'est retenue qu'une fois sa 3e bougie HTF clôturée, donc toujours *avant* l'entrée.
2. **Retracement** en 1m : un *lower high* et un *micro low* se forment sous le high de l'impulsion.
3. **Sweep** : le prix casse le micro low (fausse cassure baissière) et sa mèche **touche la FVG**
   sans clôturer en dessous.
4. **Entrée** à la **clôture de la première bougie haussière** après le sweep
   (la bougie du sweep elle-même compte si elle clôture verte).
5. **SL** sous le plus bas du sweep (plus un buffer en ticks). **TP** sur le high de l'impulsion.
   Le setup est ignoré si le RR est inférieur au minimum choisi.

### Installation sur TradingView
1. Ouvre un graphique **1 minute** (MNQ1!, NQ1!, MGC1!, GC1!, etc.).
2. Ouvre l'**Éditeur Pine** en bas de l'écran, crée un nouvel indicateur et colle tout le contenu du fichier `.pine`.
3. Clique sur **Ajouter au graphique**.

Pour chaque setup détecté, l'indicateur affiche la FVG utilisée, le sweep, les niveaux
entrée / SL / TP et le résultat (TP ou SL). Un tableau en haut à droite donne le nombre de
trades, le winrate et le total en R sur l'historique chargé.

### Réglages principaux
| Réglage | Défaut | Rôle |
|---|---|---|
| FVG TF 1/2/3 | 2m / 3m / 5m | Unités de temps des FVG prises en compte |
| Force des swings | 1 | Nombre de bougies de chaque côté pour valider un swing 1m |
| Exiger un lower high | oui | Le retracement doit montrer une vraie micro-structure baissière |
| Exiger la cassure d'un micro low | oui | Le sweep doit casser un swing low du retracement |
| Bougies max entre sweep et entrée | 5 | Délai après lequel le setup est abandonné |
| Buffer SL | 2 ticks | Marge sous le sweep |
| RR minimum | 1.0 | Filtre les setups où le TP est trop proche |

### Alertes
- `Setup LONG` / `Setup SHORT` sont disponibles via *Créer une alerte → condition SweepFVG*.
- L'option **« N'importe quel appel de la fonction alert() »** envoie aussi un message JSON
  `{"ticker","side","entry","sl","tp"}`. Il servira plus tard à brancher l'exécution automatique sur Tradovate par webhook.

### Limites de la v1
- C'est une **détection visuelle**, pas encore un backtest rigoureux : les stats ne tiennent pas compte des commissions ni du slippage.
- Si le SL et le TP sont touchés dans la même bougie 1m, le trade est compté perdant (choix prudent).
- Un seul setup à la fois par direction.
