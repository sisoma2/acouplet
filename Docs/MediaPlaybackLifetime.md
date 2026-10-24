# Media playback lifetime

The direct app requests Pause from the current macOS media player when quitting
or restarting. A separate `--media-playback-watch` worker requests Pause if the
app exits unexpectedly, including termination signals and force-quit. Normal
shutdown disarms the worker after pausing, and duplicate launches do not create
a watcher. Cancelling termination re-arms the pause request for the next quit.

Acouplet does not resume playback automatically. Players and browser videos must
support macOS media controls to respond. Public-API builds omit this integration.
The existing background-service startup behavior is unchanged.

Run `python3 Helpers/MediaPlaybackLifetimeCheck.py` for process-based coverage of
Quit, restart, cancelled termination, duplicate launch, unexpected exit, SIGTERM,
SIGKILL and parent death before watcher registration. The check uses a recording
pause command and does not control a real player. It also runs through
`python3 Packaging/check-all.py`.

Manually confirm pause behavior with a supported music player and browser video,
including normal Quit and an unexpected app exit.
