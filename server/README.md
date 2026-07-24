# Strike Protocol server

Requires Python 3.9 or newer and no third-party packages.

From the repository root, start the authoritative TCP server with:

```powershell
python -m strike_protocol.server.server --host 0.0.0.0 --port 8765
```

Run the protocol smoke test with:

```powershell
python -m strike_protocol.server.test_server
```

The file can also be run directly:

```powershell
python strike_protocol/server/test_server.py
```

Clients on the same LAN connect to the host computer's LAN address and TCP
port `8765`. Allow inbound TCP `8765` in the host firewall. Internet play also
requires port forwarding or a publicly reachable server. Do not expose a
development machine directly when a small hosted server is available.

Useful options:

```text
--host ADDRESS       Listen address (default 0.0.0.0)
--port PORT           TCP port (default 8765)
--tick-rate HZ        Simulation/snapshot rate (default 30)
--idle-timeout SEC    Disconnect timeout (default 20)
--verbose             Debug connection logging
```

See `../protocol.md` for the complete newline-delimited JSON contract.
