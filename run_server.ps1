$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $repositoryRoot

python -m strike_protocol.server.server --host 0.0.0.0 --port 8765 @args

