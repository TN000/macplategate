#!/bin/bash
# LaunchAgent — autostart SPZ.app při loginu uživatele.
# Per-user (no sudo). Pro headless gate scénář (autostart i bez login):
#   sudo cp .../app.macplategate.plist /Library/LaunchDaemons/  (a změnit ProgramArguments na "open" path)
set -e
LA_DIR="$HOME/Library/LaunchAgents"
LA_DST="$LA_DIR/app.macplategate.plist"
mkdir -p "$LA_DIR"

cat > "$LA_DST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>app.macplategate</string>
    <key>ProgramArguments</key>
    <array>
        <!-- Spouštíme binárku přímo, ne přes `open -a`. Důvod: open(1) exituje
             hned po launche → launchd sleduje `open`, ne SPZ.app, a KeepAlive
             nikdy nerestartuje crashlý SPZ. Direct exec = launchd vidí přímo
             proces SPZ a restartuje ho při pádu. -->
        <string>/Applications/SPZ.app/Contents/MacOS/SPZ</string>
    </array>
    <key>RunAtLoad</key><true/>
    <!-- KeepAlive = true (ne dict se SuccessfulExit=false) — restart VŽDY po
         exit. Dřívější dict variant znamenal "jen restart po crashi (exit ≠0)",
         ale SPZ.cleanShutdown() dělá exit(0) při SIGTERM → launchd to považoval
         za success → nerestartoval. V provozu chceme Mac mini aby vždy držel
         SPZ.app naživu; explicitní stop = `launchctl unload`, ne `pkill`. -->
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>10</integer>
    <!-- stderr je uvnitř app přesměrován na ~/Library/Application Support/SPZ/spz.log
         (SPZApp.stderrRedirect). Tyto keys jsou redundantní ale neškodí —
         zachytí early-boot errors před stderrRedirect setupem. -->
    <key>StandardOutPath</key><string>/tmp/spz.launchagent.out.log</string>
    <key>StandardErrorPath</key><string>/tmp/spz.launchagent.err.log</string>
</dict>
</plist>
EOF

launchctl unload "$LA_DST" 2>/dev/null || true
launchctl load "$LA_DST"
echo "✓ LaunchAgent installed: $LA_DST"
echo "✓ Bude autostartovat SPZ.app při každém loginu"
echo ""
echo "Stop: launchctl unload $LA_DST"
echo "Uninstall: rm $LA_DST"
echo ""
echo "Headless tip (analýza doporučuje):"
echo "  sudo pmset -a sleep 0 autorestart 1 womp 1   # nikdy nespí, autostart po výpadku"
echo "  Disable FileVault                              # autoboot bez unlock obrazovky"
