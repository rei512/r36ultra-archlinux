# Start the GUI on the panel. /etc/profile runs this for login shells; other
# logins (the serial console, ssh) fall through to a normal shell.
#
# Holding SELECT while the device boots keeps it at the shell - the way back in
# when a change breaks the GUI and the panel is the only screen at hand. Any
# button name r36u-status knows works here (A, B, X, Y, L1, R1, START, FN, ...);
# if the buttons cannot be read at all, the GUI starts as usual.
if [ "$(tty)" = /dev/tty1 ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
	if /usr/local/bin/r36u-status -p SEL; then
		echo "SELECT held: the GUI was not started. Run start-sway for it."
	else
		/usr/local/bin/start-sway
	fi
fi
