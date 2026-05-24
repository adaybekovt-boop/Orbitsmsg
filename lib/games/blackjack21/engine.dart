// Port of src/games/blackjack21/engine.js (solo half).
//
// Pure rules engine — no Flutter, no IO. Mirrors the JS API surface so the
// view layer reads almost identically to Blackjack21.jsx. Only the solo
// branch is ported here; the PvP branch lives in netProtocol.js + the peer
// stack which haven't been brought over to Flutter yet.

import 'dart:math';

const List<String> _ranks = [
  'A', '2', '3', '4', '5', '6', '7', '8', '9', '10', 'J', 'Q', 'K',
];
const List<String> _suits = ['♠', '♥', '♦', '♣'];

const int defaultBalance = 3000;
const int defaultBet = 75;
const int minBet = 25;
const int betStep = 25;

int _idCounter = 0;

class BjCard {
  final String rank;
  final String suit;
  final int id;
  const BjCard({required this.rank, required this.suit, required this.id});

  bool get isRed => suit == '♥' || suit == '♦';
}

List<BjCard> _createDeck() {
  final out = <BjCard>[];
  for (final s in _suits) {
    for (final r in _ranks) {
      _idCounter += 1;
      out.add(BjCard(rank: r, suit: s, id: _idCounter));
    }
  }
  return out;
}

List<BjCard> _shuffle(List<BjCard> deck, Random rng) {
  final a = List<BjCard>.from(deck);
  for (var i = a.length - 1; i > 0; i--) {
    final j = rng.nextInt(i + 1);
    final tmp = a[i];
    a[i] = a[j];
    a[j] = tmp;
  }
  return a;
}

/// Best hand value ≤ 21 when possible; otherwise the lowest (busted) value.
int handValue(List<BjCard> hand) {
  var sum = 0;
  var aces = 0;
  for (final c in hand) {
    if (c.rank == 'A') {
      sum += 11;
      aces += 1;
    } else if (c.rank == 'J' || c.rank == 'Q' || c.rank == 'K') {
      sum += 10;
    } else {
      sum += int.parse(c.rank);
    }
  }
  while (sum > 21 && aces > 0) {
    sum -= 10;
    aces -= 1;
  }
  return sum;
}

bool isBlackjack(List<BjCard> hand) =>
    hand.length == 2 && handValue(hand) == 21;

// Phase machine — string keys keep parity with the JS engine so the UI
// can branch on identical literals.
//   'idle'         — pre-game, no cards yet
//   'player'       — waiting for player to hit / stand / double
//   'dealerReveal' — stand was pressed, hole card about to flip
//   'dealer'       — dealer drawing cards
//   'done'         — round finished, result is set

// Result strings — mirror JS:
//   'blackjack' | 'player' | 'dealer' | 'push' | 'bust' | 'dealerBust'

class BjEvent {
  final String type;
  final BjCard? card;
  const BjEvent(this.type, {this.card});
}

class BjSnapshot {
  final List<BjCard> player;
  final List<BjCard> dealer;
  final String phase;
  final String? result;
  final int round;
  final int wins;
  final int losses;
  final int pushes;
  final int playerValue;
  final int dealerValue;
  final int dealerVisibleValue;
  final int balance;
  final int bet;
  final int pot;
  final bool doubled;
  final int lastDelta;
  final bool canDouble;

  const BjSnapshot({
    required this.player,
    required this.dealer,
    required this.phase,
    required this.result,
    required this.round,
    required this.wins,
    required this.losses,
    required this.pushes,
    required this.playerValue,
    required this.dealerValue,
    required this.dealerVisibleValue,
    required this.balance,
    required this.bet,
    required this.pot,
    required this.doubled,
    required this.lastDelta,
    required this.canDouble,
  });
}

class BlackjackEngine {
  final Random _rng;
  List<BjCard> _deck = const [];
  List<BjCard> _player = [];
  List<BjCard> _dealer = [];
  String _phase = 'idle';
  String? _result;
  int _round = 0;
  int _wins = 0;
  int _losses = 0;
  int _pushes = 0;
  final List<BjEvent> _events = [];
  int _balance;
  int _bet = defaultBet;
  // The player's chosen stake, independent of an in-round double-down. `_bet`
  // is mutated to `2×` by `doubleDown`; without this snapshot the doubled
  // stake would silently carry into every subsequent round.
  int _baseBet = defaultBet;
  int _pot = 0;
  bool _doubled = false;
  int _lastDelta = 0;

  BlackjackEngine({int startingBalance = defaultBalance, Random? rng})
      : _balance = startingBalance,
        _rng = rng ?? Random();

  BjCard _draw() {
    if (_deck.isEmpty) _deck = _shuffle(_createDeck(), _rng);
    return _deck.removeLast();
  }

  bool setBet(int next) {
    if (_phase != 'idle' && _phase != 'done') return false;
    final stepped = (next ~/ betStep) * betStep;
    final clamped = max(minBet, min(stepped, _balance));
    _bet = clamped;
    _baseBet = clamped;
    return true;
  }

  bool adjustBet(int delta) => setBet(_bet + delta);

  void _settle(String outcome) {
    // Translate outcomes to balance changes. Natural blackjack pays 3:2 like
    // a casino, normal wins pay 1:1, pushes return the stake.
    if (outcome == 'blackjack') {
      final winnings = (_bet * 2.5).floor();
      _balance += winnings;
      _lastDelta = winnings - _bet;
      _pot = 0;
    } else if (outcome == 'player' || outcome == 'dealerBust') {
      _balance += _pot;
      _lastDelta = _pot - _bet;
      _pot = 0;
    } else if (outcome == 'push') {
      _balance += _bet;
      _lastDelta = 0;
      _pot = 0;
    } else {
      // 'dealer' win or 'bust' — stake already removed; pot lost to house.
      _lastDelta = -_bet;
      _pot = 0;
    }
    if (_balance < minBet) _balance = minBet; // prevent soft-lock
  }

  bool deal() {
    // Restore the chosen stake — a prior round's double-down leaves `_bet`
    // doubled, and that must not bleed into the next deal.
    _bet = _baseBet;
    if (_balance < _bet) return false;
    _deck = _shuffle(_createDeck(), _rng);
    _player = [_draw(), _draw()];
    _dealer = [_draw(), _draw()];
    _result = null;
    _round += 1;
    _doubled = false;
    _lastDelta = 0;
    _balance -= _bet;
    _pot = _bet * 2;
    _events.add(const BjEvent('deal'));

    final pBj = isBlackjack(_player);
    final dBj = isBlackjack(_dealer);
    if (pBj && dBj) {
      _phase = 'done';
      _result = 'push';
      _pushes += 1;
      _events.add(const BjEvent('reveal'));
      _events.add(const BjEvent('push'));
      _settle('push');
    } else if (pBj) {
      _phase = 'done';
      _result = 'blackjack';
      _wins += 1;
      _events.add(const BjEvent('blackjack'));
      _settle('blackjack');
    } else if (dBj) {
      _phase = 'done';
      _result = 'dealer';
      _losses += 1;
      _events.add(const BjEvent('reveal'));
      _events.add(const BjEvent('lose'));
      _settle('dealer');
    } else {
      _phase = 'player';
    }
    return true;
  }

  bool hit() {
    if (_phase != 'player') return false;
    final card = _draw();
    _player.add(card);
    _events.add(BjEvent('hit', card: card));
    if (handValue(_player) > 21) {
      _phase = 'done';
      _result = 'bust';
      _losses += 1;
      _events.add(const BjEvent('bust'));
      _settle('bust');
    }
    return true;
  }

  bool _canDouble() =>
      _phase == 'player' &&
      _player.length == 2 &&
      !_doubled &&
      _balance >= _bet;

  bool doubleDown() {
    if (!_canDouble()) return false;
    _balance -= _bet;
    _pot += _bet * 2;
    _bet *= 2;
    _doubled = true;
    _events.add(const BjEvent('double'));
    final card = _draw();
    _player.add(card);
    _events.add(BjEvent('hit', card: card));
    if (handValue(_player) > 21) {
      _phase = 'done';
      _result = 'bust';
      _losses += 1;
      _events.add(const BjEvent('bust'));
      _settle('bust');
      return true;
    }
    _phase = 'dealerReveal';
    _events.add(const BjEvent('reveal'));
    return true;
  }

  bool stand() {
    if (_phase != 'player') return false;
    _phase = 'dealerReveal';
    _events.add(const BjEvent('reveal'));
    return true;
  }

  bool startDealerTurn() {
    if (_phase != 'dealerReveal') return false;
    _phase = 'dealer';
    return true;
  }

  /// Returns true if the dealer drew a card. False when they stand on ≥17.
  bool dealerStep() {
    if (_phase != 'dealer') return false;
    if (handValue(_dealer) < 17) {
      final card = _draw();
      _dealer.add(card);
      _events.add(BjEvent('dealerHit', card: card));
      return true;
    }
    return false;
  }

  bool resolve() {
    if (_phase != 'dealer') return false;
    final pv = handValue(_player);
    final dv = handValue(_dealer);
    _phase = 'done';
    if (dv > 21) {
      _result = 'dealerBust';
      _wins += 1;
      _events.add(const BjEvent('win'));
      _settle('dealerBust');
    } else if (pv > dv) {
      _result = 'player';
      _wins += 1;
      _events.add(const BjEvent('win'));
      _settle('player');
    } else if (pv == dv) {
      _result = 'push';
      _pushes += 1;
      _events.add(const BjEvent('push'));
      _settle('push');
    } else {
      _result = 'dealer';
      _losses += 1;
      _events.add(const BjEvent('lose'));
      _settle('dealer');
    }
    return true;
  }

  void reset() {
    _deck = const [];
    _player = [];
    _dealer = [];
    _phase = 'idle';
    _result = null;
    _round = 0;
    _wins = 0;
    _losses = 0;
    _pushes = 0;
    _events.clear();
    _balance = defaultBalance;
    _bet = defaultBet;
    _baseBet = defaultBet;
    _pot = 0;
    _doubled = false;
    _lastDelta = 0;
  }

  BjSnapshot snapshot() {
    final dealerVisible =
        _dealer.isNotEmpty ? handValue([_dealer.first]) : 0;
    return BjSnapshot(
      player: List.unmodifiable(_player),
      dealer: List.unmodifiable(_dealer),
      phase: _phase,
      result: _result,
      round: _round,
      wins: _wins,
      losses: _losses,
      pushes: _pushes,
      playerValue: handValue(_player),
      dealerValue: handValue(_dealer),
      dealerVisibleValue: dealerVisible,
      balance: _balance,
      bet: _bet,
      pot: _pot,
      doubled: _doubled,
      lastDelta: _lastDelta,
      canDouble: _canDouble(),
    );
  }

  List<BjEvent> drainEvents() {
    final out = List<BjEvent>.from(_events);
    _events.clear();
    return out;
  }
}
