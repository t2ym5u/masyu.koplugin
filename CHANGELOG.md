# Changelog

All notable changes to this project will be documented in this file.

## [1.1.10] - 2026-07-31

### Fixed
- `board_widget.lua` referenced Blitbuffer color constants that don't
  exist (COLOR_GRAY_C / COLOR_GRAY_8), which evaluated to `nil` and crashed the
  color-comparison in `paintTo()` as soon as the corresponding
  highlight was drawn. Now uses the correct constant name(s)
  (COLOR_DARK_GRAY / COLOR_LIGHT_GRAY).

## [1.1.7] - 2026-07-28

### Fixed
- The win-check never required the marked cells to form a *single*
  connected loop — only that they satisfy the pearl/degree rules as a
  union of cycles. This meant almost any generated puzzle admitted a
  completely unrelated valid marking elsewhere on the grid, even when
  every possible clue was revealed. Added single-loop-connectivity to the
  win-check and reworked generation to verify each puzzle's uniqueness
  before accepting it. 6×6 puzzles are now guaranteed to have a unique
  solution; 8×8 is a documented partial improvement (see README).
