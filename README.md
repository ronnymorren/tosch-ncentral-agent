# tosch-ncentral-agent

Reinstalls the N-central (N-able) Windows agent on a device, for use from a Sophos Central Live Response session.

```
powershell -ep bypass -c "irm https://raw.githubusercontent.com/ronnymorren/tosch-ncentral-agent/main/install.ps1 | iex"
```

The script downloads `WindowsAgentSetup.exe` from ncod691.n-able.com, checks that it is validly signed by N-ABLE TECHNOLOGIES LTD, installs it silently and waits until `Windows Agent Service` runs. The device registers under "Herinstallatie Site" in N-central; move it to the right customer afterwards.
