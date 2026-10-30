# Changelog

All notable changes to this project will be documented in this file.

## [1.0.0] - 2026-10-30

### Added
- First release: Mosaic (Fill-a-Pix) with four sizes (8×8 to 15×15) and
  three difficulty levels.
- Puzzles are generated from a random blob picture and dug down clue by clue,
  each removal checked by a graded logical solver, so every puzzle has a
  unique solution reachable by reasoning alone.
- Tap cycles shaded / empty / clear, hold marks a cell empty.
- Clues dim once satisfied and are framed when they can no longer be.
- Hint button driven by the solver: it offers the simplest cell deducible
  from your current marks, after first pointing out any wrong cell.
- Check, Undo, Clear All, timer, and auto-save of the game in progress.
- Fast generation: about 0.13 s worst case at 15×15 hard on a desktop (the
  solver keeps per-clue counts up to date instead of recounting). A progress
  bar shows when generation takes longer, as it can on an e-reader.
- Generation is a pure function of the random seed (no clock-based limits),
  so the Daily Challenge is the same everywhere.
