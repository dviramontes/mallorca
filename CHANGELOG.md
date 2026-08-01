# Changelog

All notable changes to Mallorca are documented in this file.

## [Unreleased]

[2026.08.01] add: keyboard zoom for the grid display — `Cmd/Ctrl` + `+` / `-`
scales cells and font between 50% and 300% without changing the simulation grid

### Changed

- Changed MIDI channel routing from Orca's default behavior:
  - Channel `0` broadcasts each outgoing MIDI message to all 16 MIDI channels.
  - Channels `1` through `15` send only to the matching user-facing MIDI
    channel.

  This is an intentional departure from Orca compatibility.
