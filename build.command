#!/bin/bash
# Double-click to build and install Doorman.
# (Maintenance hook: if a task.sh is waiting, it runs that once instead.)
# Output goes to build.log / task.log next to this file.
cd "$(dirname "$0")"
if [ -f task.sh ]; then
  {
    echo "=== $(date) ==="
    bash ./task.sh
    echo "EXIT CODE: $?"
  } > task.log 2>&1
  mv -f task.sh task.done.sh
else
  {
    echo "=== $(date) ==="
    bash ./build.sh
    echo "EXIT CODE: $?"
  } > build.log 2>&1
fi
osascript -e 'tell application "Terminal" to close (every window whose name contains "build.command")' >/dev/null 2>&1 &
exit 0
