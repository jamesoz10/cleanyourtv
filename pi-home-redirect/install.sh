#!/usr/bin/env bash
# Fire TV home redirect, for a Raspberry Pi on the same network as the Fire TV.
#
# Fire OS will not let another launcher own the Home button. This runs on the Pi instead: it stays
# connected to each Fire TV over ADB, watches which screen is in front, and the moment Amazon's home
# screen comes up it opens the CleanYourTV launcher (com.gathin.tvhome) on top.
#
# Install or update (one or more Fire TVs, port 5555 is added if you leave it off):
#   curl -fsSL https://raw.githubusercontent.com/jamesoz10/cleanyourtv/main/pi-home-redirect/install.sh | sudo bash -s 192.168.1.45 192.168.1.46
# Change the Fire TVs later: run it again with the new addresses.
# Logs:      journalctl -u firetv-home-redirect -f
# Pause:     sudo systemctl stop firetv-home-redirect      (start again with: sudo systemctl start ...)
# Remove:    curl -fsSL .../install.sh | sudo bash -s -- --uninstall
#
# On each Fire TV first: Settings > My Fire TV > Developer Options > ADB Debugging ON, and give it a fixed
# IP address in your router (DHCP reservation) so the Pi can always find it. The first time the Pi
# connects, the TV shows "Allow USB debugging?": tick "Always allow from this computer" and press OK.
#
# Escape hatch: press Home twice quickly (within 3 seconds of the new launcher appearing) to stay on
# Amazon's home, e.g. for its side menu. It switches back once you open a non-Amazon app or the launcher.
set -euo pipefail

NAME=firetv-home-redirect
SVC_USER=firetv-redirect
SVC_HOME=/var/lib/$SVC_USER
BIN=/usr/local/bin/$NAME.py
CONF=/etc/$NAME.conf
UNIT=/etc/systemd/system/$NAME.service

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this with sudo." >&2
  exit 1
fi

if [ "${1:-}" = "--uninstall" ]; then
  systemctl disable --now "$NAME" 2>/dev/null || true
  rm -f "$UNIT" "$BIN" "$CONF"
  systemctl daemon-reload
  userdel "$SVC_USER" 2>/dev/null || true
  rm -rf "$SVC_HOME"
  echo "Removed. Turn ADB Debugging off on the Fire TVs if you no longer need it."
  exit 0
fi

HOSTS=""
for h in "$@"; do
  case "$h" in
    *:*) HOSTS="$HOSTS $h" ;;
    *)   HOSTS="$HOSTS $h:5555" ;;
  esac
done
HOSTS="${HOSTS# }"

if [ -z "$HOSTS" ] && [ ! -f "$CONF" ]; then
  echo "Give the Fire TV's IP address, e.g.: sudo bash install.sh 192.168.1.45" >&2
  exit 1
fi

echo "== Installing adb"
if ! command -v adb >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq adb 2>/dev/null || apt-get install -y -qq android-tools-adb
fi
command -v python3 >/dev/null 2>&1 || apt-get install -y -qq python3

echo "== Creating service user $SVC_USER"
if ! id "$SVC_USER" >/dev/null 2>&1; then
  useradd --system --home-dir "$SVC_HOME" --create-home --shell /usr/sbin/nologin "$SVC_USER"
fi
mkdir -p "$SVC_HOME"
chown "$SVC_USER": "$SVC_HOME"

echo "== Writing $BIN"
cat > "$BIN" <<'PYEOF'
#!/usr/bin/env python3
"""Open the CleanYourTV launcher whenever Amazon's home screen comes up on a Fire TV.

Settings come from the environment (see /etc/firetv-home-redirect.conf):
  FIRETV_HOSTS       space-separated ip:port list, e.g. "192.168.1.45:5555 192.168.1.46:5555"
  TARGET_ACTIVITY    launcher to open (default com.gathin.tvhome/.MainActivity)
  AMAZON_HOME_REGEX  which activity counts as Amazon's home
  ESCAPE_WINDOW      seconds: Home pressed again this soon after a redirect keeps Amazon's home (0 = off)
  BOOT_GRACE         seconds after (re)connecting in which the escape hatch is ignored
  POLL_SECONDS       how often to double-check the screen in front, besides the event stream
"""
import collections
import os
import re
import subprocess
import sys
import threading
import time

ADB = os.environ.get("ADB", "adb")
HOSTS = os.environ.get("FIRETV_HOSTS", "").split()
TARGET = os.environ.get("TARGET_ACTIVITY", "com.gathin.tvhome/.MainActivity")
TARGET_PKG = TARGET.split("/")[0]
AMAZON_HOME_RE = re.compile(os.environ.get(
    "AMAZON_HOME_REGEX",
    r"^com\.amazon\.tv\.launcher/(com\.amazon\.tv\.launcher)?\.ui\.HomeActivity"))
ESCAPE_WINDOW = float(os.environ.get("ESCAPE_WINDOW", "3"))
ESCAPE_MAX = float(os.environ.get("ESCAPE_MAX", "600"))
BOOT_GRACE = float(os.environ.get("BOOT_GRACE", "90"))
POLL_SECONDS = float(os.environ.get("POLL_SECONDS", "10"))

# Fire OS 7 (Android 9) logs am_set_resumed_activity, Fire OS 8 (Android 11) wm_set_resumed_activity.
EVENT_RE = re.compile(r"(?:am|wm)_set_resumed_activity\b[^\[]*\[\d+,([^,\]]+)")
# dumpsys: "mResumedActivity: ActivityRecord{1a2b3c u0 com.amazon.tv.launcher/.ui.HomeActivity_vNext t12}"
DUMPSYS_RE = re.compile(r"u\d+ ([\w.]+/[\w.$]+)")
DUMPSYS_CMD = "dumpsys activity activities | grep -E 'mResumedActivity|topResumedActivity' | head -n 1"


def adb(args, timeout=15):
    try:
        r = subprocess.run([ADB] + args, capture_output=True, text=True, timeout=timeout)
        return r.returncode, (r.stdout + r.stderr).strip()
    except subprocess.TimeoutExpired:
        return 124, "timeout"


class Watcher(threading.Thread):
    def __init__(self, host):
        super().__init__(daemon=True, name=host)
        self.host = host
        self.lock = threading.Lock()
        self.current = None
        self.prev = None
        self.last_redirect = 0.0
        self.escaped_at = 0.0
        self.connected_at = 0.0
        self.recent = collections.deque()
        self.paused_until = 0.0

    def log(self, msg):
        print("[%s] %s" % (self.host, msg), flush=True)

    def connect(self):
        adb(["connect", self.host], timeout=20)
        _, state = adb(["-s", self.host, "get-state"], timeout=10)
        if "offline" in state:
            adb(["disconnect", self.host], timeout=10)
        return state == "device", state

    def is_amazon_home(self, comp):
        return bool(AMAZON_HOME_RE.search(comp))

    def on_resumed(self, comp):
        comp = comp.strip().rstrip("}")
        with self.lock:
            if comp == self.current:
                return
            self.prev, self.current = self.current, comp
            now = time.monotonic()

            if not self.is_amazon_home(comp):
                # Escape lasts while you stay in Amazon's own screens; any other app, or the new
                # launcher, ends it.
                if self.escaped_at and (not comp.startswith("com.amazon.") or comp.startswith(TARGET_PKG + "/")):
                    self.escaped_at = 0.0
                return

            if self.escaped_at and now - self.escaped_at < ESCAPE_MAX:
                return
            self.escaped_at = 0.0

            if (ESCAPE_WINDOW > 0 and self.prev and self.prev.startswith(TARGET_PKG + "/")
                    and now - self.last_redirect < ESCAPE_WINDOW
                    and now - self.connected_at > BOOT_GRACE):
                self.escaped_at = now
                self.log("Home pressed twice: staying on Amazon's home")
                return

            if now < self.paused_until:
                return
            self.recent.append(now)
            while self.recent and now - self.recent[0] > 30:
                self.recent.popleft()
            if len(self.recent) > 6:
                self.paused_until = now + 120
                self.recent.clear()
                self.log("Amazon's home keeps coming back (7 times in 30 s): pausing for 2 minutes")
                return
            self.last_redirect = now

        rc, out = adb(["-s", self.host, "shell", "am", "start", "-n", TARGET])
        if rc == 0 and "Error" not in out:
            self.log("Amazon's home came up: opened %s" % TARGET)
        else:
            self.log("could not open %s: %s" % (TARGET, out))

    def read_events(self, proc):
        for line in proc.stdout:
            m = EVENT_RE.search(line)
            if m:
                self.on_resumed(m.group(1))

    def poll_current(self):
        rc, out = adb(["-s", self.host, "shell", DUMPSYS_CMD], timeout=15)
        if rc != 0:
            return None
        m = DUMPSYS_RE.search(out)
        return m.group(1) if m else None

    def run(self):
        warned = None
        while True:
            ok, state = self.connect()
            if not ok:
                if state != warned:
                    if "unauthorized" in state:
                        self.log("waiting for you to accept 'Allow USB debugging?' on the TV (tick Always allow)")
                    else:
                        self.log("cannot reach the Fire TV (%s); is it on, and is ADB Debugging on?" % state)
                    warned = state
                time.sleep(10)
                continue
            warned = None
            with self.lock:
                self.connected_at = time.monotonic()
                self.current = None
                self.prev = None
            self.log("connected")

            proc = subprocess.Popen([ADB, "-s", self.host, "logcat", "-b", "events", "-T", "1"],
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                    text=True, bufsize=1)
            threading.Thread(target=self.read_events, args=(proc,), daemon=True).start()
            try:
                while proc.poll() is None:
                    comp = self.poll_current()
                    if comp:
                        self.on_resumed(comp)
                    end = time.monotonic() + POLL_SECONDS
                    while proc.poll() is None and time.monotonic() < end:
                        time.sleep(0.2)
            finally:
                if proc.poll() is None:
                    proc.kill()
            self.log("connection lost; reconnecting")
            time.sleep(5)


def main():
    if not HOSTS:
        print("FIRETV_HOSTS is empty: set it in /etc/firetv-home-redirect.conf", file=sys.stderr)
        sys.exit(1)
    adb(["start-server"], timeout=30)
    watchers = [Watcher(h) for h in HOSTS]
    for w in watchers:
        w.start()
    print("watching %s; opening %s when Amazon's home comes up" % (", ".join(HOSTS), TARGET), flush=True)
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
PYEOF
chmod 755 "$BIN"

if [ -n "$HOSTS" ]; then
  echo "== Writing $CONF"
  cat > "$CONF" <<EOF
# Fire TVs to watch, space-separated ip:port. Run install.sh again, or edit this and
# sudo systemctl restart $NAME
FIRETV_HOSTS="$HOSTS"
# Optional:
#TARGET_ACTIVITY=com.gathin.tvhome/.MainActivity
#ESCAPE_WINDOW=3
#POLL_SECONDS=10
EOF
fi

echo "== Writing $UNIT"
cat > "$UNIT" <<EOF
[Unit]
Description=Open the CleanYourTV launcher when the Fire TV home screen appears
After=network-online.target
Wants=network-online.target

[Service]
User=$SVC_USER
Environment=HOME=$SVC_HOME
EnvironmentFile=$CONF
ExecStart=/usr/bin/python3 -u $BIN
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$NAME" >/dev/null 2>&1
systemctl restart "$NAME"

echo
echo "Done. Watching: $(. "$CONF"; echo "$FIRETV_HOSTS")"
echo "Look at the TV now: if it asks 'Allow USB debugging?', tick 'Always allow from this computer' and press OK."
echo "Live log: journalctl -u $NAME -f"
