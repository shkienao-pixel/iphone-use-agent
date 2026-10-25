"""Native notification-center interaction, bound to one visible test notification."""
import re
import time
from pathlib import Path

from .live import capture, ui


def open_center(name):
    ui("home")
    time.sleep(0.8)
    frame = capture(name + "-home", bundle="com.apple.springboard")
    tree = Path(frame["tree"]).read_text()
    if "Alert," in tree:
        raise RuntimeError("Handle the observed system alert before opening Notification Center")
    ui("drag_screen", bundle="com.apple.springboard", frameID=frame["frameID"],
       x=0.2, y=0.005, endX=0.2, endY=0.75)
    time.sleep(0.7)
    return capture(name + "-center", bundle="com.apple.springboard")


def swipe_notification(name, title, frame=None):
    if title not in ["海棠通知 A", "海棠通知 B"]:
        raise RuntimeError("Only fixed, non-secret notification fixtures may be opened")
    frame = frame or capture(name + "-center", bundle="com.apple.springboard")
    for attempt in range(3):
        tree = Path(frame["tree"]).read_text()
        candidates = [line for line in tree.splitlines()
                      if "Button," in line and "identifier: 'ShortLook.Platter.Content.Seamless'" in line
                      and title in line and "任务已完成" in line]
        if len(candidates) != 1:
            raise RuntimeError("Exactly one notification for the specified fixture is required")
        bounds = re.search(r"\{\{([\d.]+), ([\d.]+)\}, \{([\d.]+), ([\d.]+)\}\}", candidates[0])
        windows = re.findall(r"Window.*?\{\{0\.0, 0\.0\}, \{([\d.]+), ([\d.]+)\}\}", tree)
        if not bounds or not windows:
            raise RuntimeError("Observed screen and notification bounds are required")
        screen_height = max(float(h) for _, h in windows)
        _, y, _, h = map(float, bounds.groups())
        if y + h <= screen_height:
            break
        if attempt == 2 or "SBCoverSheetWindow" not in tree:
            raise RuntimeError("Notification history could not be brought fully on screen")
        # The current OS initially hides older notifications below the fold.
        # Reveal that history before attempting its required horizontal gesture.
        ui("swipe_up", bundle="com.apple.springboard")
        time.sleep(0.7)
        frame = capture(name + "-history-" + str(attempt + 1), bundle="com.apple.springboard")
    windows = re.findall(r"Window.*?\{\{0\.0, 0\.0\}, \{([\d.]+), ([\d.]+)\}\}", tree)
    if not windows:
        raise RuntimeError("An actual screen geometry snapshot is required")
    width, height = max(((float(w), float(h)) for w, h in windows), key=lambda p: p[0] * p[1])
    rows = [line for line in tree.splitlines()
            if "Button," in line and "identifier: 'ShortLook.Platter.Content.Seamless'" in line
            and title in line and "任务已完成" in line]
    if len(rows) != 1:
        raise RuntimeError("Exactly one visible notification for the specified fixture is required")
    match = re.search(r"\{\{([\d.]+), ([\d.]+)\}, \{([\d.]+), ([\d.]+)\}\}", rows[0])
    if not match:
        raise RuntimeError("Notification bounds are unavailable")
    x, y, w, h = map(float, match.groups())
    if not (0 <= x < x + w <= width and 0 <= y < y + h <= height):
        raise RuntimeError("Notification is not fully on screen")
    ui("drag_screen", bundle="com.apple.springboard", frameID=frame["frameID"],
       x=(x + w * 0.1) / width, y=(y + h * 0.5) / height,
       endX=(x + w * 0.94) / width, endY=(y + h * 0.5) / height)
    return {"frame": frame, "notificationBounds": [x, y, w, h], "screenPoints": [width, height],
            "interaction": "right swipe required by the observed system Notification Center"}
