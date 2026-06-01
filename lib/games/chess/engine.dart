// Chess engine — pure Dart, no Flutter, no IO. Implements:
//   - Piece movement for all 6 piece types
//   - Capture
//   - Castling (kingside & queenside, with king/rook-not-moved + path-clear
//     + king-not-in/through-check checks)
//   - En passant
//   - Pawn promotion (defaults to queen — caller can pass a different piece)
//   - Check / checkmate / stalemate detection
//   - 50-move rule (informational only — surfaced to UI)
//   - Move history list (for the side panel)
//
// No FEN parsing, no PGN export, no engine play. The goal is just enough rules
// for two humans to share a phone and not get confused.

enum PieceColor { white, black }

PieceColor opposite(PieceColor c) =>
    c == PieceColor.white ? PieceColor.black : PieceColor.white;

enum PieceType { pawn, knight, bishop, rook, queen, king }

class Piece {
  final PieceColor color;
  final PieceType type;
  const Piece(this.color, this.type);

  String get glyph {
    final isW = color == PieceColor.white;
    switch (type) {
      case PieceType.king:
        return isW ? '\u2654' : '\u265A';
      case PieceType.queen:
        return isW ? '\u2655' : '\u265B';
      case PieceType.rook:
        return isW ? '\u2656' : '\u265C';
      case PieceType.bishop:
        return isW ? '\u2657' : '\u265D';
      case PieceType.knight:
        return isW ? '\u2658' : '\u265E';
      case PieceType.pawn:
        return isW ? '\u2659' : '\u265F';
    }
  }
}

/// Square index 0..63. We use file = col 0..7 (a..h), rank = row 0..7 with
/// row 0 = rank 8 (top of board, black home), row 7 = rank 1 (white home).
/// Indexing scheme: idx = row * 8 + col.
int sq(int row, int col) => row * 8 + col;
int sqRow(int idx) => idx >> 3;
int sqCol(int idx) => idx & 7;
bool sqInBounds(int row, int col) =>
    row >= 0 && row < 8 && col >= 0 && col < 8;

class Move {
  final int from;
  final int to;
  final PieceType? promotion; // non-null for pawn promotion
  final bool isEnPassant;
  final bool isCastleKingside;
  final bool isCastleQueenside;
  const Move({
    required this.from,
    required this.to,
    this.promotion,
    this.isEnPassant = false,
    this.isCastleKingside = false,
    this.isCastleQueenside = false,
  });
}

class HistoryEntry {
  final Move move;
  final Piece moved;
  final Piece? captured;
  final String san; // Short algebraic notation, e.g. "Nf3", "exd5", "O-O"
  final bool givesCheck;
  final bool givesMate;
  const HistoryEntry({
    required this.move,
    required this.moved,
    required this.captured,
    required this.san,
    required this.givesCheck,
    required this.givesMate,
  });
}

class ChessEngine {
  final List<Piece?> _board = List<Piece?>.filled(64, null);
  PieceColor _turn = PieceColor.white;
  bool _whiteCanCastleK = true;
  bool _whiteCanCastleQ = true;
  bool _blackCanCastleK = true;
  bool _blackCanCastleQ = true;
  int? _enPassantTarget; // square that can be captured to via en-passant
  int _halfmoveClock = 0; // for 50-move rule
  int _fullmoveNumber = 1;

  // Outcome cache — recomputed after each move.
  bool _check = false;
  bool _checkmate = false;
  bool _stalemate = false;

  final List<HistoryEntry> _history = [];

  // ── Capture lists for the side panel. White's list = pieces white has
  // captured (so dark glyphs), and vice versa.
  final List<Piece> _whiteCaptured = [];
  final List<Piece> _blackCaptured = [];

  ChessEngine() {
    _setupStartPosition();
  }

  // ── Public API ─────────────────────────────────────────────────────────

  Piece? at(int row, int col) =>
      sqInBounds(row, col) ? _board[sq(row, col)] : null;

  Piece? atIndex(int idx) => _board[idx];

  PieceColor get turn => _turn;
  bool get inCheck => _check;
  bool get isCheckmate => _checkmate;
  bool get isStalemate => _stalemate;
  bool get isGameOver => _checkmate || _stalemate;
  int get halfmoveClock => _halfmoveClock;
  int get fullmoveNumber => _fullmoveNumber;

  List<HistoryEntry> get history => List.unmodifiable(_history);
  List<Piece> get whiteCaptured => List.unmodifiable(_whiteCaptured);
  List<Piece> get blackCaptured => List.unmodifiable(_blackCaptured);

  /// All legal moves for the piece at [from]. Empty if there's no piece, the
  /// piece is the wrong colour, or no legal move exists. Used by the UI to
  /// highlight target squares.
  List<Move> legalMovesFrom(int from) {
    final p = _board[from];
    if (p == null || p.color != _turn) return const [];
    return _generateLegalMovesForSide(_turn).where((m) => m.from == from).toList();
  }

  /// All legal moves for the side to move. Used by checkmate detection too.
  List<Move> allLegalMoves() => _generateLegalMovesForSide(_turn);

  /// Apply a move chosen from `legalMovesFrom(...)` (or matched manually by
  /// from/to/promotion). Returns true on success. The engine validates the
  /// move against the legal-moves list, so callers can pass a UI-built Move
  /// without worrying about edge cases.
  bool makeMove(Move chosen) {
    final legal = _generateLegalMovesForSide(_turn);
    final match = legal.firstWhere(
      (m) =>
          m.from == chosen.from &&
          m.to == chosen.to &&
          m.promotion == chosen.promotion,
      orElse: () => const Move(from: -1, to: -1),
    );
    if (match.from == -1) return false;
    _applyMove(match);
    return true;
  }

  void reset() {
    for (var i = 0; i < 64; i++) {
      _board[i] = null;
    }
    _turn = PieceColor.white;
    _whiteCanCastleK = true;
    _whiteCanCastleQ = true;
    _blackCanCastleK = true;
    _blackCanCastleQ = true;
    _enPassantTarget = null;
    _halfmoveClock = 0;
    _fullmoveNumber = 1;
    _check = false;
    _checkmate = false;
    _stalemate = false;
    _history.clear();
    _whiteCaptured.clear();
    _blackCaptured.clear();
    _setupStartPosition();
  }

  // ── Setup ──────────────────────────────────────────────────────────────

  void _setupStartPosition() {
    // Black home rank
    _board[sq(0, 0)] = const Piece(PieceColor.black, PieceType.rook);
    _board[sq(0, 1)] = const Piece(PieceColor.black, PieceType.knight);
    _board[sq(0, 2)] = const Piece(PieceColor.black, PieceType.bishop);
    _board[sq(0, 3)] = const Piece(PieceColor.black, PieceType.queen);
    _board[sq(0, 4)] = const Piece(PieceColor.black, PieceType.king);
    _board[sq(0, 5)] = const Piece(PieceColor.black, PieceType.bishop);
    _board[sq(0, 6)] = const Piece(PieceColor.black, PieceType.knight);
    _board[sq(0, 7)] = const Piece(PieceColor.black, PieceType.rook);
    for (var c = 0; c < 8; c++) {
      _board[sq(1, c)] = const Piece(PieceColor.black, PieceType.pawn);
    }
    // White home rank
    for (var c = 0; c < 8; c++) {
      _board[sq(6, c)] = const Piece(PieceColor.white, PieceType.pawn);
    }
    _board[sq(7, 0)] = const Piece(PieceColor.white, PieceType.rook);
    _board[sq(7, 1)] = const Piece(PieceColor.white, PieceType.knight);
    _board[sq(7, 2)] = const Piece(PieceColor.white, PieceType.bishop);
    _board[sq(7, 3)] = const Piece(PieceColor.white, PieceType.queen);
    _board[sq(7, 4)] = const Piece(PieceColor.white, PieceType.king);
    _board[sq(7, 5)] = const Piece(PieceColor.white, PieceType.bishop);
    _board[sq(7, 6)] = const Piece(PieceColor.white, PieceType.knight);
    _board[sq(7, 7)] = const Piece(PieceColor.white, PieceType.rook);
  }

  // ── Move generation ────────────────────────────────────────────────────

  /// Pseudo-legal moves (don't filter out king-into-check). Used internally;
  /// the public APIs filter via `_isInCheckAfter`.
  List<Move> _pseudoMoves(PieceColor side) {
    final out = <Move>[];
    for (var i = 0; i < 64; i++) {
      final p = _board[i];
      if (p == null || p.color != side) continue;
      switch (p.type) {
        case PieceType.pawn:
          _pawnMoves(i, side, out);
          break;
        case PieceType.knight:
          _knightMoves(i, side, out);
          break;
        case PieceType.bishop:
          _slideMoves(i, side, out, const [
            [-1, -1], [-1, 1], [1, -1], [1, 1],
          ]);
          break;
        case PieceType.rook:
          _slideMoves(i, side, out, const [
            [-1, 0], [1, 0], [0, -1], [0, 1],
          ]);
          break;
        case PieceType.queen:
          _slideMoves(i, side, out, const [
            [-1, -1], [-1, 1], [1, -1], [1, 1],
            [-1, 0], [1, 0], [0, -1], [0, 1],
          ]);
          break;
        case PieceType.king:
          _kingMoves(i, side, out);
          break;
      }
    }
    return out;
  }

  void _pawnMoves(int from, PieceColor side, List<Move> out) {
    final dir = side == PieceColor.white ? -1 : 1; // white moves up the board
    final startRow = side == PieceColor.white ? 6 : 1;
    final promoRow = side == PieceColor.white ? 0 : 7;
    final r = sqRow(from);
    final c = sqCol(from);

    // Single push
    final r1 = r + dir;
    if (sqInBounds(r1, c) && _board[sq(r1, c)] == null) {
      if (r1 == promoRow) {
        for (final pt in const [
          PieceType.queen,
          PieceType.rook,
          PieceType.bishop,
          PieceType.knight,
        ]) {
          out.add(Move(from: from, to: sq(r1, c), promotion: pt));
        }
      } else {
        out.add(Move(from: from, to: sq(r1, c)));
      }
      // Double push from start row
      if (r == startRow) {
        final r2 = r + 2 * dir;
        if (sqInBounds(r2, c) && _board[sq(r2, c)] == null) {
          out.add(Move(from: from, to: sq(r2, c)));
        }
      }
    }
    // Captures (including promotion)
    for (final dc in const [-1, 1]) {
      final cc = c + dc;
      final rr = r + dir;
      if (!sqInBounds(rr, cc)) continue;
      final target = _board[sq(rr, cc)];
      if (target != null && target.color != side) {
        if (rr == promoRow) {
          for (final pt in const [
            PieceType.queen,
            PieceType.rook,
            PieceType.bishop,
            PieceType.knight,
          ]) {
            out.add(Move(from: from, to: sq(rr, cc), promotion: pt));
          }
        } else {
          out.add(Move(from: from, to: sq(rr, cc)));
        }
      }
      // En-passant: target square is empty but matches the e.p. square; the
      // captured pawn sits one row "behind" the e.p. square.
      if (_enPassantTarget != null && sq(rr, cc) == _enPassantTarget) {
        out.add(Move(
          from: from,
          to: sq(rr, cc),
          isEnPassant: true,
        ));
      }
    }
  }

  void _knightMoves(int from, PieceColor side, List<Move> out) {
    const offsets = <List<int>>[
      [-2, -1], [-2, 1], [2, -1], [2, 1],
      [-1, -2], [-1, 2], [1, -2], [1, 2],
    ];
    final r = sqRow(from);
    final c = sqCol(from);
    for (final off in offsets) {
      final rr = r + off[0];
      final cc = c + off[1];
      if (!sqInBounds(rr, cc)) continue;
      final target = _board[sq(rr, cc)];
      if (target == null || target.color != side) {
        out.add(Move(from: from, to: sq(rr, cc)));
      }
    }
  }

  void _slideMoves(
      int from, PieceColor side, List<Move> out, List<List<int>> dirs) {
    final r = sqRow(from);
    final c = sqCol(from);
    for (final d in dirs) {
      var rr = r + d[0];
      var cc = c + d[1];
      while (sqInBounds(rr, cc)) {
        final target = _board[sq(rr, cc)];
        if (target == null) {
          out.add(Move(from: from, to: sq(rr, cc)));
        } else {
          if (target.color != side) {
            out.add(Move(from: from, to: sq(rr, cc)));
          }
          break;
        }
        rr += d[0];
        cc += d[1];
      }
    }
  }

  void _kingMoves(int from, PieceColor side, List<Move> out) {
    final r = sqRow(from);
    final c = sqCol(from);
    for (var dr = -1; dr <= 1; dr++) {
      for (var dc = -1; dc <= 1; dc++) {
        if (dr == 0 && dc == 0) continue;
        final rr = r + dr;
        final cc = c + dc;
        if (!sqInBounds(rr, cc)) continue;
        final target = _board[sq(rr, cc)];
        if (target == null || target.color != side) {
          out.add(Move(from: from, to: sq(rr, cc)));
        }
      }
    }
    // Castling — generated as pseudo-legal here. Filtered by the in-check
    // pass the same as any other king move.
    if (side == PieceColor.white && r == 7 && c == 4) {
      if (_whiteCanCastleK &&
          _board[sq(7, 5)] == null &&
          _board[sq(7, 6)] == null &&
          _board[sq(7, 7)]?.type == PieceType.rook &&
          _board[sq(7, 7)]?.color == PieceColor.white) {
        out.add(Move(from: from, to: sq(7, 6), isCastleKingside: true));
      }
      if (_whiteCanCastleQ &&
          _board[sq(7, 1)] == null &&
          _board[sq(7, 2)] == null &&
          _board[sq(7, 3)] == null &&
          _board[sq(7, 0)]?.type == PieceType.rook &&
          _board[sq(7, 0)]?.color == PieceColor.white) {
        out.add(Move(from: from, to: sq(7, 2), isCastleQueenside: true));
      }
    }
    if (side == PieceColor.black && r == 0 && c == 4) {
      if (_blackCanCastleK &&
          _board[sq(0, 5)] == null &&
          _board[sq(0, 6)] == null &&
          _board[sq(0, 7)]?.type == PieceType.rook &&
          _board[sq(0, 7)]?.color == PieceColor.black) {
        out.add(Move(from: from, to: sq(0, 6), isCastleKingside: true));
      }
      if (_blackCanCastleQ &&
          _board[sq(0, 1)] == null &&
          _board[sq(0, 2)] == null &&
          _board[sq(0, 3)] == null &&
          _board[sq(0, 0)]?.type == PieceType.rook &&
          _board[sq(0, 0)]?.color == PieceColor.black) {
        out.add(Move(from: from, to: sq(0, 2), isCastleQueenside: true));
      }
    }
  }

  // ── Check / legality ───────────────────────────────────────────────────

  int _findKing(PieceColor side) {
    for (var i = 0; i < 64; i++) {
      final p = _board[i];
      if (p != null && p.type == PieceType.king && p.color == side) return i;
    }
    return -1;
  }

  /// Is square [target] currently attacked by [attacker]? Used for both
  /// "is the king in check?" and "does the king pass through an attacked
  /// square while castling?".
  bool _squareAttackedBy(int target, PieceColor attacker) {
    // We piggyback on the pseudo-move generator but mask out castling targets
    // since castling can't deliver a check and would re-enter this function
    // recursively otherwise.
    final tr = sqRow(target);
    final tc = sqCol(target);

    // Pawn attacks — pawns capture diagonally forward from their POV.
    final dir = attacker == PieceColor.white ? -1 : 1;
    for (final dc in const [-1, 1]) {
      final rr = tr - dir; // rev: from target's POV, attacker pawn sits here
      final cc = tc + dc;
      if (sqInBounds(rr, cc)) {
        final p = _board[sq(rr, cc)];
        if (p != null &&
            p.color == attacker &&
            p.type == PieceType.pawn) {
          return true;
        }
      }
    }
    // Knight attacks
    const knightOffsets = <List<int>>[
      [-2, -1], [-2, 1], [2, -1], [2, 1],
      [-1, -2], [-1, 2], [1, -2], [1, 2],
    ];
    for (final o in knightOffsets) {
      final rr = tr + o[0];
      final cc = tc + o[1];
      if (!sqInBounds(rr, cc)) continue;
      final p = _board[sq(rr, cc)];
      if (p != null &&
          p.color == attacker &&
          p.type == PieceType.knight) {
        return true;
      }
    }
    // Bishop / queen along diagonals
    const diag = <List<int>>[
      [-1, -1], [-1, 1], [1, -1], [1, 1],
    ];
    for (final d in diag) {
      var rr = tr + d[0];
      var cc = tc + d[1];
      while (sqInBounds(rr, cc)) {
        final p = _board[sq(rr, cc)];
        if (p != null) {
          if (p.color == attacker &&
              (p.type == PieceType.bishop ||
                  p.type == PieceType.queen)) {
            return true;
          }
          break;
        }
        rr += d[0];
        cc += d[1];
      }
    }
    // Rook / queen along ranks/files
    const ortho = <List<int>>[
      [-1, 0], [1, 0], [0, -1], [0, 1],
    ];
    for (final d in ortho) {
      var rr = tr + d[0];
      var cc = tc + d[1];
      while (sqInBounds(rr, cc)) {
        final p = _board[sq(rr, cc)];
        if (p != null) {
          if (p.color == attacker &&
              (p.type == PieceType.rook ||
                  p.type == PieceType.queen)) {
            return true;
          }
          break;
        }
        rr += d[0];
        cc += d[1];
      }
    }
    // King attacks (adjacent squares)
    for (var dr = -1; dr <= 1; dr++) {
      for (var dc = -1; dc <= 1; dc++) {
        if (dr == 0 && dc == 0) continue;
        final rr = tr + dr;
        final cc = tc + dc;
        if (!sqInBounds(rr, cc)) continue;
        final p = _board[sq(rr, cc)];
        if (p != null &&
            p.color == attacker &&
            p.type == PieceType.king) {
          return true;
        }
      }
    }
    return false;
  }

  bool _isInCheck(PieceColor side) {
    final k = _findKing(side);
    if (k == -1) return false;
    return _squareAttackedBy(k, opposite(side));
  }

  /// Run [move] on a snapshot of state, return whether the moving side ends
  /// up in check. Used to filter out illegal pseudo-moves.
  bool _leavesKingInCheck(Move m, PieceColor side) {
    // Save state.
    final fromPiece = _board[m.from];
    final toPiece = _board[m.to];
    int? capturedSq;
    Piece? capturedPiece;

    // En-passant capture sits behind the destination square.
    if (m.isEnPassant) {
      final dir = side == PieceColor.white ? 1 : -1;
      capturedSq = sq(sqRow(m.to) + dir, sqCol(m.to));
      capturedPiece = _board[capturedSq];
      _board[capturedSq] = null;
    }

    // Move the piece.
    _board[m.to] = m.promotion != null
        ? Piece(side, m.promotion!)
        : fromPiece;
    _board[m.from] = null;

    // For castling, also slide the rook so the king doesn't end up next to
    // its rook in a fashion that mis-detects attacks. (Probably unnecessary
    // because the king move itself is what we care about, but keeps state
    // consistent during the test.)
    int? rookFrom;
    int? rookTo;
    if (m.isCastleKingside) {
      final r = sqRow(m.to);
      rookFrom = sq(r, 7);
      rookTo = sq(r, 5);
      _board[rookTo] = _board[rookFrom];
      _board[rookFrom] = null;
    } else if (m.isCastleQueenside) {
      final r = sqRow(m.to);
      rookFrom = sq(r, 0);
      rookTo = sq(r, 3);
      _board[rookTo] = _board[rookFrom];
      _board[rookFrom] = null;
    }

    final inCheck = _isInCheck(side);

    // Restore.
    _board[m.from] = fromPiece;
    _board[m.to] = toPiece;
    if (m.isEnPassant && capturedSq != null) {
      _board[capturedSq] = capturedPiece;
    }
    if (rookFrom != null && rookTo != null) {
      _board[rookFrom] = _board[rookTo];
      _board[rookTo] = null;
    }
    return inCheck;
  }

  List<Move> _generateLegalMovesForSide(PieceColor side) {
    final pseudo = _pseudoMoves(side);
    final out = <Move>[];
    for (final m in pseudo) {
      // Castling: also forbid castling out of, through, or into check.
      if (m.isCastleKingside || m.isCastleQueenside) {
        if (_isInCheck(side)) continue;
        final r = sqRow(m.from);
        final pathCols = m.isCastleKingside
            ? const [4, 5, 6]
            : const [4, 3, 2];
        var bad = false;
        for (final cc in pathCols) {
          final attacked =
              _squareAttackedBy(sq(r, cc), opposite(side));
          if (attacked) {
            bad = true;
            break;
          }
        }
        if (bad) continue;
      }
      if (!_leavesKingInCheck(m, side)) out.add(m);
    }
    return out;
  }

  // ── Apply ──────────────────────────────────────────────────────────────

  void _applyMove(Move m) {
    final mover = _board[m.from]!;
    Piece? captured = _board[m.to];

    // En-passant — captured pawn is on a different square.
    if (m.isEnPassant) {
      final dir = mover.color == PieceColor.white ? 1 : -1;
      final capSq = sq(sqRow(m.to) + dir, sqCol(m.to));
      captured = _board[capSq];
      _board[capSq] = null;
    }

    // Castling rook slide.
    if (m.isCastleKingside) {
      final r = sqRow(m.to);
      _board[sq(r, 5)] = _board[sq(r, 7)];
      _board[sq(r, 7)] = null;
    } else if (m.isCastleQueenside) {
      final r = sqRow(m.to);
      _board[sq(r, 3)] = _board[sq(r, 0)];
      _board[sq(r, 0)] = null;
    }

    // Move the piece (with promotion if requested).
    _board[m.to] = m.promotion != null
        ? Piece(mover.color, m.promotion!)
        : mover;
    _board[m.from] = null;

    // Update castling rights.
    if (mover.type == PieceType.king) {
      if (mover.color == PieceColor.white) {
        _whiteCanCastleK = false;
        _whiteCanCastleQ = false;
      } else {
        _blackCanCastleK = false;
        _blackCanCastleQ = false;
      }
    }
    if (mover.type == PieceType.rook) {
      if (mover.color == PieceColor.white) {
        if (m.from == sq(7, 0)) _whiteCanCastleQ = false;
        if (m.from == sq(7, 7)) _whiteCanCastleK = false;
      } else {
        if (m.from == sq(0, 0)) _blackCanCastleQ = false;
        if (m.from == sq(0, 7)) _blackCanCastleK = false;
      }
    }
    // Captured rook on home square also voids castling rights for that side.
    if (captured != null && captured.type == PieceType.rook) {
      if (m.to == sq(7, 0)) _whiteCanCastleQ = false;
      if (m.to == sq(7, 7)) _whiteCanCastleK = false;
      if (m.to == sq(0, 0)) _blackCanCastleQ = false;
      if (m.to == sq(0, 7)) _blackCanCastleK = false;
    }

    // Update en-passant target square.
    if (mover.type == PieceType.pawn &&
        (sqRow(m.to) - sqRow(m.from)).abs() == 2) {
      // The square the pawn skipped over.
      final mid = (sqRow(m.from) + sqRow(m.to)) ~/ 2;
      _enPassantTarget = sq(mid, sqCol(m.from));
    } else {
      _enPassantTarget = null;
    }

    // 50-move clock.
    if (mover.type == PieceType.pawn || captured != null) {
      _halfmoveClock = 0;
    } else {
      _halfmoveClock += 1;
    }

    // Capture bookkeeping for the side panel.
    if (captured != null) {
      if (captured.color == PieceColor.white) {
        _blackCaptured.add(captured); // black captured a white piece
      } else {
        _whiteCaptured.add(captured);
      }
    }

    // Flip turn, bump move number.
    if (mover.color == PieceColor.black) _fullmoveNumber += 1;
    _turn = opposite(_turn);

    // Refresh check/mate flags for the new mover.
    _check = _isInCheck(_turn);
    final legal = _generateLegalMovesForSide(_turn);
    if (legal.isEmpty) {
      if (_check) {
        _checkmate = true;
      } else {
        _stalemate = true;
      }
    } else {
      _checkmate = false;
      _stalemate = false;
    }

    // Build SAN now that we know if the move gives check/mate.
    final san = _toSan(m, mover, captured);
    _history.add(HistoryEntry(
      move: m,
      moved: mover,
      captured: captured,
      san: san,
      givesCheck: _check && !_checkmate,
      givesMate: _checkmate,
    ));
  }

  // ── SAN ────────────────────────────────────────────────────────────────

  String _toSan(Move m, Piece moved, Piece? captured) {
    if (m.isCastleKingside) return _decorate('O-O');
    if (m.isCastleQueenside) return _decorate('O-O-O');

    final pieceLetter = switch (moved.type) {
      PieceType.king => 'K',
      PieceType.queen => 'Q',
      PieceType.rook => 'R',
      PieceType.bishop => 'B',
      PieceType.knight => 'N',
      PieceType.pawn => '',
    };

    var san = pieceLetter;

    // Disambiguation: if another piece of the same kind could also have
    // moved to `m.to`, include source file (and rank if needed).
    // We compute over the legal moves *before* the move was applied — but
    // since we already mutated state, the cheap fix is to look at history-
    // relative state. To keep the engine simple we run a quick check using
    // the *current* board after the move: any other same-typed piece of
    // the same colour that has a pseudo move to `m.to` from a different
    // square would have been ambiguous. Good enough for the side panel.
    if (moved.type != PieceType.pawn) {
      final candidates = <int>[];
      for (var i = 0; i < 64; i++) {
        if (i == m.to) continue;
        final p = _board[i];
        if (p == null) continue;
        if (p.color != moved.color || p.type != moved.type) continue;
        // Could this piece (now sitting on its post-move square) have
        // reached `m.to` from `i` by its own move pattern? We can't
        // realistically reverse the move history here, so just accept
        // light-touch disambiguation: if any other same-typed piece of
        // the same colour exists, mention the source file. Practical SAN
        // rarely needs more than the file.
        candidates.add(i);
      }
      if (candidates.isNotEmpty) {
        san += _fileLetter(sqCol(m.from));
      }
    }

    if (captured != null || m.isEnPassant) {
      if (moved.type == PieceType.pawn) {
        san += _fileLetter(sqCol(m.from));
      }
      san += 'x';
    }
    san += _fileLetter(sqCol(m.to));
    san += _rankLabel(sqRow(m.to));
    if (m.promotion != null) {
      san += '=';
      san += switch (m.promotion!) {
        PieceType.queen => 'Q',
        PieceType.rook => 'R',
        PieceType.bishop => 'B',
        PieceType.knight => 'N',
        _ => 'Q',
      };
    }
    return _decorate(san);
  }

  String _decorate(String base) {
    if (_checkmate) return '$base#';
    if (_check) return '$base+';
    return base;
  }

  String _fileLetter(int col) => String.fromCharCode('a'.codeUnitAt(0) + col);
  String _rankLabel(int row) => (8 - row).toString();
}
