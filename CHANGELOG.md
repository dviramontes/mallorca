# Changelog

All notable changes to Mallorca are documented in this file.

## [Unreleased]

### Changed

- Changed MIDI channel routing from Orca's default behavior:
  - Channel `0` broadcasts each outgoing MIDI message to all 16 MIDI channels.
  - Channels `1` through `15` send only to the matching user-facing MIDI
    channel.

  This is an intentional departure from Orca compatibility.
