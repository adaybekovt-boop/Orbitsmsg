// Blackjack-21 — solo vs bot. Port of src/games/blackjack21/Blackjack21.jsx
// (solo branch). The PvP branch needs the peer layer, which isn't ported
// yet, so this version drops straight into a single-player table.
//
// Layout mirrors the web "21 — minimal" mockup: header, round meta strip,
// dealer hand on top, divider with pot or result pill, player hand on
// bottom, action bar with bet stepper + Hit/Stand/×2/Split row.

import 'package:flutter/material.dart';

import '../../core/haptics.dart';
import '../../themes/orbits_tokens.dart';
import 'engine.dart';
import 'sound.dart';

class BlackjackPage extends StatefulWidget {
  final VoidCallback? onExit;
  const BlackjackPage({super.key, this.onExit});

  @override
  State<BlackjackPage> createState() => _BlackjackPageState();
}

class _BlackjackPageState extends State<BlackjackPage> {
  final BlackjackEngine _engine = BlackjackEngine();
  late BjSnapshot _snap;
  bool _sound = true;

  @override
  void initState() {
    super.initState();
    _snap = _engine.snapshot();
  }

  void _commit() {
    final s = _engine.snapshot();
    final events = _engine.drainEvents();
    for (final ev in events) {
      switch (ev.type) {
        case 'deal':
          bjSfx.deal();
          break;
        case 'hit':
          bjSfx.hit();
          break;
        case 'reveal':
          bjSfx.flip();
          break;
        case 'dealerHit':
          bjSfx.hit();
          break;
        case 'double':
          bjSfx.deal();
          break;
        case 'bust':
          bjSfx.bust();
          break;
        case 'blackjack':
          bjSfx.blackjack();
          break;
        case 'win':
          bjSfx.win();
          break;
        case 'lose':
          bjSfx.lose();
          break;
        case 'push':
          bjSfx.push();
          break;
      }
    }
    if (mounted) setState(() => _snap = s);

    // Drive the dealer phases on a small delay so the player can see each
    // card flip / draw individually instead of resolving in one frame.
    if (s.phase == 'dealerReveal') {
      Future.delayed(const Duration(milliseconds: 700), () {
        if (!mounted) return;
        _engine.startDealerTurn();
        _commit();
      });
    } else if (s.phase == 'dealer') {
      Future.delayed(const Duration(milliseconds: 550), () {
        if (!mounted) return;
        final drew = _engine.dealerStep();
        if (!drew) _engine.resolve();
        _commit();
      });
    }
  }

  void _deal() {
    if (_snap.phase != 'idle' && _snap.phase != 'done') return;
    hapticTap();
    _engine.deal();
    _commit();
  }

  void _hit() {
    if (_snap.phase != 'player') return;
    hapticTap();
    _engine.hit();
    _commit();
  }

  void _stand() {
    if (_snap.phase != 'player') return;
    hapticTap();
    _engine.stand();
    _commit();
  }

  void _double() {
    if (!_snap.canDouble) return;
    hapticTap();
    _engine.doubleDown();
    _commit();
  }

  void _changeBet(int next) {
    if (_engine.setBet(next)) {
      hapticTap();
      setState(() => _snap = _engine.snapshot());
    }
  }

  void _reset() {
    hapticTap();
    _engine.reset();
    _commit();
  }

  void _toggleSound() {
    hapticTap();
    setState(() {
      _sound = !_sound;
      setBjSoundEnabled(_sound);
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    final isIdle = _snap.phase == 'idle';
    final isDone = _snap.phase == 'done';
    final canPlay = _snap.phase == 'player';
    final hideHole = _snap.phase == 'player';
    final dealerDisplay = hideHole ? _snap.dealerVisibleValue : _snap.dealerValue;

    return Scaffold(
      backgroundColor: tokens.bg,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(tokens),
            _buildRoundMeta(tokens),
            Expanded(
              child: isIdle
                  ? _buildIntro(tokens)
                  : _buildTable(tokens, hideHole, dealerDisplay),
            ),
            if (!isIdle) _buildActionBar(tokens, canPlay, isDone),
          ],
        ),
      ),
    );
  }

  // ── Header ──────────────────────────────────────────────────────────────

  Widget _buildHeader(OrbitsTokens tokens) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tokens.border)),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: () {
              hapticTap();
              widget.onExit?.call();
            },
            icon: Icon(Icons.arrow_back, color: tokens.text),
            tooltip: 'Назад',
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '21 — minimal',
                  style: TextStyle(
                    fontFamily: tokens.fontHeading,
                    color: tokens.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Orbits',
                  style: TextStyle(
                    fontFamily: tokens.fontMono,
                    color: tokens.muted,
                    fontSize: 10,
                    letterSpacing: 1.5,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: _toggleSound,
            icon: Icon(
              _sound ? Icons.volume_up : Icons.volume_off,
              color: tokens.muted,
            ),
            tooltip: _sound ? 'Выключить звук' : 'Включить звук',
          ),
          IconButton(
            onPressed: _reset,
            icon: Icon(Icons.refresh, color: tokens.muted),
            tooltip: 'Сбросить счёт',
          ),
        ],
      ),
    );
  }

  // ── Round meta ──────────────────────────────────────────────────────────

  Widget _buildRoundMeta(OrbitsTokens tokens) {
    final round =
        _snap.round > 0 ? _snap.round.toString().padLeft(2, '0') : '01';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _MetaCell(label: 'РАУНД', value: round),
          const _MetaCell(label: 'ЦЕЛЬ —', value: '21'),
        ],
      ),
    );
  }

  // ── Idle / intro ────────────────────────────────────────────────────────

  Widget _buildIntro(OrbitsTokens tokens) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'ORBITS',
                style: TextStyle(
                  fontFamily: tokens.fontMono,
                  color: tokens.muted,
                  fontSize: 10,
                  letterSpacing: 4,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '21 — minimal',
                style: TextStyle(
                  fontFamily: tokens.fontHeading,
                  color: tokens.text,
                  fontSize: 28,
                  fontWeight: FontWeight.w300,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: 280,
                child: Text(
                  'Набери больше очков, чем дилер, но не больше 21. '
                  'Туз — 1 или 11, картинки — 10.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: tokens.fontBody,
                    color: tokens.muted,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              _BetStepper(
                tokens: tokens,
                bet: _snap.bet,
                onMinus: () => _changeBet(_snap.bet - betStep),
                onPlus: () => _changeBet(_snap.bet + betStep),
                minusDisabled: _snap.bet <= minBet,
                plusDisabled: _snap.bet + betStep > _snap.balance,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _deal,
                style: FilledButton.styleFrom(
                  backgroundColor: tokens.text,
                  foregroundColor: tokens.bg,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 28, vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
                  'Начать раунд',
                  style: TextStyle(
                    fontFamily: tokens.fontHeading,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              DefaultTextStyle(
                style: TextStyle(
                  fontFamily: tokens.fontMono,
                  color: tokens.muted,
                  fontSize: 10,
                  letterSpacing: 1.2,
                ),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  alignment: WrapAlignment.center,
                  children: [
                    Text.rich(TextSpan(children: [
                      const TextSpan(text: 'БАЛАНС  '),
                      TextSpan(
                        text: _snap.balance.toString(),
                        style: TextStyle(color: tokens.text),
                      ),
                    ])),
                    const Text('·'),
                    Text(
                        'ПОБЕД ${_snap.wins} · ПОРАЖ. ${_snap.losses}'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Active table ────────────────────────────────────────────────────────

  Widget _buildTable(
      OrbitsTokens tokens, bool hideHole, int dealerDisplay) {
    return SingleChildScrollView(
      child: Column(
        children: [
          // Dealer area
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Дилер',
                      style: TextStyle(
                        fontFamily: tokens.fontBody,
                        color: tokens.muted,
                        fontSize: 13,
                      ),
                    ),
                    Text(
                      'СТАВКА  ${_snap.bet}',
                      style: TextStyle(
                        fontFamily: tokens.fontMono,
                        color: tokens.muted,
                        fontSize: 10,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _Hand(
                  cards: _snap.dealer,
                  hideHoleIndex:
                      hideHole && _snap.dealer.length > 1 ? 1 : -1,
                  tokens: tokens,
                ),
                const SizedBox(height: 12),
                _Score(
                  tokens: tokens,
                  value: dealerDisplay,
                  dim: hideHole,
                  hidden: hideHole && _snap.dealer.isNotEmpty,
                ),
              ],
            ),
          ),
          // Divider with pot or result pill
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              children: [
                Expanded(child: Divider(color: tokens.border, height: 1)),
                const SizedBox(width: 12),
                _snap.phase == 'done'
                    ? _ResultPill(tokens: tokens, result: _snap.result)
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'БАНК ',
                            style: TextStyle(
                              fontFamily: tokens.fontMono,
                              color: tokens.muted,
                              fontSize: 9,
                              letterSpacing: 1.5,
                            ),
                          ),
                          Text(
                            _snap.pot.toString(),
                            style: TextStyle(
                              fontFamily: tokens.fontMono,
                              color: tokens.text,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                const SizedBox(width: 12),
                Expanded(child: Divider(color: tokens.border, height: 1)),
              ],
            ),
          ),
          // Player area
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
            child: Column(
              children: [
                _Score(
                  tokens: tokens,
                  value: _snap.playerValue,
                  aux: 'ТВОЯ РУКА',
                ),
                const SizedBox(height: 12),
                _Hand(cards: _snap.player, tokens: tokens),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Ты',
                      style: TextStyle(
                        fontFamily: tokens.fontBody,
                        color: tokens.text,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      'БАЛАНС  ${_snap.balance}',
                      style: TextStyle(
                        fontFamily: tokens.fontMono,
                        color: tokens.muted,
                        fontSize: 10,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Action bar ──────────────────────────────────────────────────────────

  Widget _buildActionBar(OrbitsTokens tokens, bool canPlay, bool isDone) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: tokens.bg,
        border: Border(top: BorderSide(color: tokens.border)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                'СТАВКА',
                style: TextStyle(
                  fontFamily: tokens.fontMono,
                  color: tokens.muted,
                  fontSize: 10,
                  letterSpacing: 1.2,
                ),
              ),
              const Spacer(),
              _BetStepper(
                tokens: tokens,
                bet: _snap.bet,
                onMinus: () => _changeBet(_snap.bet - betStep),
                onPlus: () => _changeBet(_snap.bet + betStep),
                minusDisabled: !isDone || _snap.bet <= minBet,
                plusDisabled:
                    !isDone || _snap.bet + betStep > _snap.balance,
              ),
              const Spacer(),
              Text(
                'CHIPS',
                style: TextStyle(
                  fontFamily: tokens.fontMono,
                  color: tokens.muted,
                  fontSize: 10,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (isDone)
            Row(
              children: [
                Expanded(
                  child: _ActionBtn(
                    tokens: tokens,
                    label: 'Ещё раз',
                    primary: true,
                    onTap: _deal,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _ActionBtn(
                    tokens: tokens,
                    label: 'Выйти',
                    onTap: () {
                      hapticTap();
                      widget.onExit?.call();
                    },
                  ),
                ),
              ],
            )
          else
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: _ActionBtn(
                    tokens: tokens,
                    label: 'Hit',
                    primary: true,
                    onTap: canPlay ? _hit : null,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _ActionBtn(
                    tokens: tokens,
                    label: 'Stand',
                    onTap: canPlay ? _stand : null,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _ActionBtn(
                    tokens: tokens,
                    label: '×2',
                    onTap: canPlay && _snap.canDouble ? _double : null,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _ActionBtn(
                    tokens: tokens,
                    label: 'Split',
                    onTap: null,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

// ─── Leaf widgets ─────────────────────────────────────────────────────────

class _MetaCell extends StatelessWidget {
  final String label;
  final String value;
  const _MetaCell({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            fontFamily: tokens.fontMono,
            color: tokens.muted,
            fontSize: 10,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          value,
          style: TextStyle(
            fontFamily: tokens.fontMono,
            color: tokens.text,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _Hand extends StatelessWidget {
  final List<BjCard> cards;
  final int hideHoleIndex;
  final OrbitsTokens tokens;
  const _Hand({
    required this.cards,
    required this.tokens,
    this.hideHoleIndex = -1,
  });

  @override
  Widget build(BuildContext context) {
    if (cards.isEmpty) {
      return SizedBox(height: 92, child: Container());
    }
    return SizedBox(
      height: 96,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < cards.length; i++) ...[
            if (i > 0) const SizedBox(width: 6),
            _PlayingCard(
              card: cards[i],
              hidden: i == hideHoleIndex,
              tokens: tokens,
            ),
          ],
        ],
      ),
    );
  }
}

class _PlayingCard extends StatelessWidget {
  final BjCard card;
  final bool hidden;
  final OrbitsTokens tokens;
  const _PlayingCard({
    required this.card,
    required this.hidden,
    required this.tokens,
  });

  @override
  Widget build(BuildContext context) {
    if (hidden) return _CardBack(tokens: tokens);
    final color = card.isRed ? tokens.danger : tokens.text;
    return Container(
      width: 66,
      height: 92,
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: tokens.border),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Top corner
          _CornerMark(rank: card.rank, suit: card.suit, color: color),
          const Spacer(),
          // Bottom corner — rotated
          Transform.rotate(
            angle: 3.14159265,
            child: _CornerMark(
              rank: card.rank,
              suit: card.suit,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _CornerMark extends StatelessWidget {
  final String rank;
  final String suit;
  final Color color;
  const _CornerMark({
    required this.rank,
    required this.suit,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          rank,
          style: TextStyle(
            color: color,
            fontSize: 22,
            fontWeight: FontWeight.w500,
            height: 1,
            letterSpacing: -0.6,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          suit,
          style: TextStyle(
            color: color,
            fontSize: 14,
            height: 1,
          ),
        ),
      ],
    );
  }
}

class _CardBack extends StatelessWidget {
  final OrbitsTokens tokens;
  const _CardBack({required this.tokens});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 66,
      height: 92,
      decoration: BoxDecoration(
        color: tokens.text,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: tokens.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white24),
            borderRadius: BorderRadius.circular(6),
          ),
        ),
      ),
    );
  }
}

class _Score extends StatelessWidget {
  final OrbitsTokens tokens;
  final int value;
  final bool dim;
  final bool hidden;
  final String? aux;
  const _Score({
    required this.tokens,
    required this.value,
    this.dim = false,
    this.hidden = false,
    this.aux,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              value.toString(),
              style: TextStyle(
                color: dim ? tokens.muted : tokens.text,
                fontSize: 56,
                fontWeight: FontWeight.w300,
                height: 1,
                letterSpacing: -2,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            if (hidden)
              Padding(
                padding: const EdgeInsets.only(bottom: 8, left: 4),
                child: Text(
                  '+?',
                  style: TextStyle(
                    color: tokens.muted.withValues(alpha: 0.5),
                    fontSize: 30,
                    fontWeight: FontWeight.w300,
                    height: 1,
                  ),
                ),
              ),
          ],
        ),
        if (aux != null) ...[
          const SizedBox(height: 6),
          Text(
            aux!,
            style: TextStyle(
              fontFamily: tokens.fontMono,
              color: tokens.muted,
              fontSize: 10,
              letterSpacing: 1.5,
            ),
          ),
        ],
      ],
    );
  }
}

class _ResultPill extends StatelessWidget {
  final OrbitsTokens tokens;
  final String? result;
  const _ResultPill({required this.tokens, required this.result});

  @override
  Widget build(BuildContext context) {
    if (result == null) return const SizedBox.shrink();
    String label;
    Color tone;
    switch (result) {
      case 'blackjack':
        label = 'БЛЭКДЖЕК';
        tone = tokens.success;
        break;
      case 'player':
        label = 'ПОБЕДА';
        tone = tokens.success;
        break;
      case 'dealerBust':
        label = 'ДИЛЕР ПЕРЕБРАЛ';
        tone = tokens.success;
        break;
      case 'dealer':
        label = 'ДИЛЕР ВЫИГРАЛ';
        tone = tokens.danger;
        break;
      case 'bust':
        label = 'ПЕРЕБОР';
        tone = tokens.danger;
        break;
      case 'push':
        label = 'НИЧЬЯ';
        tone = tokens.muted;
        break;
      default:
        return const SizedBox.shrink();
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: tokens.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tone.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: tokens.fontMono,
          color: tone,
          fontSize: 10,
          letterSpacing: 1.5,
        ),
      ),
    );
  }
}

class _BetStepper extends StatelessWidget {
  final OrbitsTokens tokens;
  final int bet;
  final VoidCallback onMinus;
  final VoidCallback onPlus;
  final bool minusDisabled;
  final bool plusDisabled;
  const _BetStepper({
    required this.tokens,
    required this.bet,
    required this.onMinus,
    required this.onPlus,
    required this.minusDisabled,
    required this.plusDisabled,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _StepButton(
          tokens: tokens,
          icon: Icons.remove,
          onTap: minusDisabled ? null : onMinus,
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 50,
          child: Text(
            bet.toString(),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: tokens.fontMono,
              color: tokens.text,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 12),
        _StepButton(
          tokens: tokens,
          icon: Icons.add,
          onTap: plusDisabled ? null : onPlus,
        ),
      ],
    );
  }
}

class _StepButton extends StatelessWidget {
  final OrbitsTokens tokens;
  final IconData icon;
  final VoidCallback? onTap;
  const _StepButton({
    required this.tokens,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return Opacity(
      opacity: disabled ? 0.4 : 1,
      child: Material(
        color: tokens.surface,
        shape: CircleBorder(side: BorderSide(color: tokens.border)),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 28,
            height: 28,
            child: Icon(icon, size: 14, color: tokens.text),
          ),
        ),
      ),
    );
  }
}

class _ActionBtn extends StatelessWidget {
  final OrbitsTokens tokens;
  final String label;
  final bool primary;
  final VoidCallback? onTap;
  const _ActionBtn({
    required this.tokens,
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    final bg = primary ? tokens.text : tokens.surface;
    final fg = primary ? tokens.bg : tokens.text;
    return Opacity(
      opacity: disabled ? 0.5 : 1,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
            height: 46,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: primary ? tokens.text : tokens.border,
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontFamily: tokens.fontHeading,
                color: disabled ? tokens.muted : fg,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
