# Contributing

Mallorca is pre-release software. Bug reports, fixes, documentation
improvements, and focused new features are welcome.

## Reporting bugs

Search the [issue tracker](https://github.com/dviramontes/mallorca/issues)
before opening a new report. Include:

- The Mallorca commit or release you tested.
- Your macOS and Odin versions.
- Clear steps to reproduce the problem.
- What you expected and what happened instead.
- A minimal `.orca` patch, when relevant.
- Relevant logs. Run Mallorca with `--debug` to include MIDI output details.

Please remove private information, credentials, and unrelated project data from
reports and attachments.

## Proposing changes

Open an issue before starting a large feature or a change to VM behavior. Small
bug fixes and documentation corrections can go directly to a pull request.

Orca-c is the semantic reference for the VM. Preserve its behavior unless the
change deliberately departs from compatibility; document intentional
differences in the pull request and in [CHANGELOG.md](CHANGELOG.md).

Keep the architecture split intact:

- `src/core/` contains the headless VM and has no rendering, timing, MIDI, or
  filesystem access.
- The host owns rendering, timing, MIDI, networking, and file I/O.

## Development setup

Fetch the pinned karl2d dependency before the first build:

```sh
just setup
```

Then type-check and test the project:

```sh
just fmt
just check
just test
```

Use the `Justfile` recipes for application builds so the required
`KARL2D_AUDIO_BACKEND=nil` definition is applied.

## Pull requests

Keep pull requests focused and explain the user-visible result. Add or update
tests for behavior changes, update documentation when behavior changes, and add
notable user-facing changes to the changelog.

Before submitting:

```sh
just fmt
just check
just test
```

Include reproduction steps or an example patch when they help reviewers verify
the change. Pull requests are welcome.
