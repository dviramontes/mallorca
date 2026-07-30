# Mallorca server

Phoenix relay and browser client for Mallorca's network demo.

The demo uses one fixed room, `MYROOM`. Start the server, then open
[`localhost:4000`](http://localhost:4000). Browsers join automatically with a
server-assigned Orca operator name; there is no room-code or display-name form.
The active-session list lets each browser watch the native grid or another
browser's grid. Only a browser's own session is editable.

```sh
mix setup
mix phx.server
```

The native client can connect without requesting a room and will be attached to
`MYROOM`. Its legacy `/room/:code` browser URL remains accepted, but every such
URL opens the fixed demo room.
