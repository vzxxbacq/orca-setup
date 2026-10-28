"""Small curses interface for server setup; no third-party terminal dependencies."""

import curses
import os
import subprocess
import textwrap
import unicodedata


class Cancelled(Exception):
    """Return to the previous screen without committing the current form."""


def clean(value):
    """Prevent terminal control characters in paths or configuration from being rendered."""
    return "".join(char if char.isprintable() else " " for char in str(value))


def width(value):
    return sum(0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in "WF" else 1
               for c in value)


def clipped(value, columns):
    result = ""
    for char in clean(value):
        if width(result + char) > columns:
            break
        result += char
    return result


class Screen:
    def __init__(self, window, path):
        self.window = window
        self.path = path
        self.stage = "SETUP / OVERVIEW"
        self.status = "No changes written"
        self.notes = []
        window.keypad(True)
        curses.noecho()
        curses.cbreak()
        curses.set_escdelay(25)
        self.cursor(False)
        self.accent = curses.A_BOLD
        self.muted = curses.A_DIM
        self.selected = curses.A_REVERSE | curses.A_BOLD
        self.good = curses.A_BOLD
        if curses.has_colors() and "NO_COLOR" not in os.environ:
            curses.start_color()
            try:
                curses.use_default_colors()
                background = -1
            except curses.error:
                background = curses.COLOR_BLACK
            curses.init_pair(1, curses.COLOR_CYAN, background)
            curses.init_pair(2, curses.COLOR_BLACK, curses.COLOR_CYAN)
            curses.init_pair(3, curses.COLOR_GREEN, background)
            self.accent |= curses.color_pair(1)
            self.selected = curses.color_pair(2) | curses.A_BOLD
            self.good |= curses.color_pair(3)

    @staticmethod
    def cursor(visible):
        try:
            curses.curs_set(1 if visible else 0)
        except curses.error:
            pass

    def put(self, y, x, value, style=0, columns=None):
        height, terminal_width = self.window.getmaxyx()
        if y < 0 or y >= height or x < 0 or x >= terminal_width - 1:
            return
        limit = terminal_width - x - 1
        if columns is not None:
            limit = min(limit, columns)
        try:
            self.window.addstr(y, x, clipped(value, limit), style)
        except curses.error:
            # A resize can race a draw; the next frame uses the updated dimensions.
            pass

    def key(self):
        key = self.window.get_wch()
        if key == "\x03":
            raise KeyboardInterrupt
        return key

    def frame(self, title, subtitle, footer):
        while True:
            self.window.erase()
            height, terminal_width = self.window.getmaxyx()
            if height >= 20 and terminal_width >= 64:
                break
            self.put(0, 0, "Orca setup needs at least 64 columns x 20 rows.", self.accent)
            self.put(2, 0, "Enlarge the terminal to continue. Esc to leave.")
            self.window.refresh()
            if self.key() in ("\x1b", "q", "0"):
                raise Cancelled
        self.put(1, 3, "ORCA", self.accent)
        self.put(1, 10, "Linux Server Setup", curses.A_BOLD)
        if terminal_width >= 90:
            self.put(1, terminal_width - 31, self.status, self.good, 28)
        self.put(2, 3, "-" * (terminal_width - 7), self.muted)
        self.put(3, 3, self.stage, self.accent)
        self.put(5, 3, title, curses.A_BOLD)
        self.put(6, 3, subtitle, self.muted)
        self.put(height - 4, 3, "-" * (terminal_width - 7), self.muted)
        self.put(height - 3, 3, "Config: " + str(self.path), self.muted)
        self.put(height - 2, 3, footer, self.accent)
        return height, terminal_width

    def lines(self, text, columns):
        result = []
        for line in str(text).splitlines():
            result.extend(textwrap.wrap(clean(line), max(1, columns), replace_whitespace=False) or [""])
        return result

    def choose(self, title, items, subtitle="Choose an option", current=0, detail="", preview=None):
        """Items are (value, label, explanation); choices always require Enter."""
        index = current
        offset = 0
        while True:
            footer = ("Up/Down Select  PgUp/PgDn Preview  Enter Open  Esc Back" if preview else
                      "Up/Down or j/k  Select   Enter  Continue   Esc  Back")
            height, terminal_width = self.frame(title, subtitle, footer)
            visible = height - 13
            start = min(max(0, index - visible + 1), max(0, len(items) - visible))
            split = min(39, terminal_width // 2)
            for row in range(8, height - 5):
                self.put(row, split - 1, "|", self.muted)
            for row, (_, label, _) in enumerate(items[start:start + visible], 8):
                active = row - 8 + start == index
                value = ("> " if active else "  ") + label
                self.put(row, 3, value.ljust(split - 5), self.selected if active else 0, split - 5)
            description = (preview(items[index][0]) + "\n\n" + items[index][2] if preview else
                           items[index][2] + ("\n\n" + detail if detail else ""))
            lines = self.lines(description, terminal_width - split - 5)
            offset = min(offset, max(0, len(lines) - visible))
            for row, line in enumerate(lines[offset:offset + visible], 8):
                style = self.good if line.startswith("* ") else self.accent if offset + row == 8 else 0
                self.put(row, split + 1, line, style)
            if preview and len(lines) > visible:
                self.put(height - 5, split + 1, f"{offset + 1}-{min(offset + visible, len(lines))}/{len(lines)} PgUp/PgDn", self.muted)
            if len(items) > visible:
                self.put(height - 5, 3, f"{index + 1} / {len(items)}  Scroll for more", self.muted)
            self.window.refresh()
            key = self.key()
            previous = index
            if key in (curses.KEY_DOWN, "j", "\t"):
                index = (index + 1) % len(items)
            elif key in (curses.KEY_UP, "k", curses.KEY_BTAB):
                index = (index - 1) % len(items)
            elif key == curses.KEY_HOME:
                index = 0
            elif key == curses.KEY_END:
                index = len(items) - 1
            elif preview and key == curses.KEY_NPAGE:
                offset += visible
            elif preview and key == curses.KEY_PPAGE:
                offset = max(0, offset - visible)
            elif key in ("\n", "\r", curses.KEY_ENTER):
                return items[index][0]
            elif key in ("\x1b", "q", "0"):
                raise Cancelled
            if index != previous:
                offset = 0

    def page(self, title, text):
        offset = 0
        while True:
            height, terminal_width = self.frame(title, "Review before continuing", "Up/Down  Scroll   Enter  Continue   Esc  Back")
            lines = self.lines(text, terminal_width - 8)
            visible = height - 13
            offset = min(offset, max(0, len(lines) - visible))
            for row, line in enumerate(lines[offset:offset + visible], 8):
                self.put(row, 4, line)
            if len(lines) > visible:
                self.put(height - 5, 3, f"Lines {offset + 1}-{min(offset + visible, len(lines))} of {len(lines)}", self.muted)
            self.window.refresh()
            key = self.key()
            if key in ("\n", "\r", curses.KEY_ENTER):
                return
            if key in ("\x1b", "q", "0"):
                raise Cancelled
            if key in (curses.KEY_DOWN, "j"):
                offset += 1
            elif key in (curses.KEY_UP, "k"):
                offset = max(0, offset - 1)
            elif key in (curses.KEY_NPAGE, " "):
                offset += visible
            elif key == curses.KEY_PPAGE:
                offset = max(0, offset - visible)

    def confirm(self, title, text, yes_label="Yes, install"):
        """Keep action buttons visible while reviewing a scrollable deployment summary."""
        accepted = False
        offset = 0
        while True:
            height, terminal_width = self.frame(
                title, "Yes validates, backs up and saves before applying.",
                "Left/Right  Choose   Enter  Confirm   Esc  Back")
            lines = self.lines(text, terminal_width - 8)
            visible = height - 15
            offset = min(offset, max(0, len(lines) - visible))
            for row, line in enumerate(lines[offset:offset + visible], 8):
                self.put(row, 4, line, self.accent if line.isupper() else 0)
            labels = ("[ " + yes_label + " ]", "[ No, go back ]")
            start = max(3, (terminal_width - sum(len(label) for label in labels) - 4) // 2)
            self.put(height - 6, start, labels[0], self.selected if accepted else self.accent)
            self.put(height - 6, start + len(labels[0]) + 4, labels[1], self.accent if accepted else self.selected)
            self.put(height - 5, 4, f"{offset + 1}-{min(offset + visible, len(lines))}/{len(lines)}  Up/Down or PgUp/PgDn to review", self.muted)
            self.window.refresh()
            key = self.key()
            if key in (curses.KEY_LEFT, curses.KEY_RIGHT, "\t", curses.KEY_BTAB):
                accepted = not accepted
            elif key in ("y", "Y"):
                accepted = True
            elif key in ("n", "N"):
                accepted = False
            elif key in ("\n", "\r", curses.KEY_ENTER):
                return accepted
            elif key in ("\x1b", "q", "0"):
                return False
            elif key in (curses.KEY_DOWN, "j"):
                offset += 1
            elif key in (curses.KEY_UP, "k"):
                offset = max(0, offset - 1)
            elif key in (curses.KEY_NPAGE, " "):
                offset += visible
            elif key == curses.KEY_PPAGE:
                offset = max(0, offset - visible)

    def prompt(self, label, current="", secret=False, help_text=""):
        # Existing passwords are never placed in the edit buffer or screen.
        value = "" if secret else str(current)
        position = len(value)
        self.cursor(True)
        try:
            while True:
                height, terminal_width = self.frame(label, "Enter keeps the current value" if secret else "Edit the value below",
                                                    "Enter  Continue   Esc  Cancel section   Ctrl-U  Clear")
                rendered = "*" * len(value) if secret else value
                available = terminal_width - 12
                start = position
                while start > 0 and width(rendered[start - 1:position]) < available:
                    start -= 1
                self.put(8, 4, " " * (terminal_width - 9), curses.A_REVERSE)
                self.put(8, 5, rendered[start:], curses.A_REVERSE, available)
                notes = help_text + "\n\n" + "\n".join(self.notes)
                for row, line in enumerate(self.lines(notes, terminal_width - 10)[:height - 15], 10):
                    self.put(row, 5, line, self.muted)
                self.window.move(8, 5 + width(rendered[start:position]))
                self.window.refresh()
                key = self.key()
                if key in ("\n", "\r", curses.KEY_ENTER):
                    return value if secret else value.strip()
                if key == "\x1b":
                    raise Cancelled
                if key in (curses.KEY_BACKSPACE, "\x7f", "\b") and position:
                    value = value[:position - 1] + value[position:]
                    position -= 1
                elif key == curses.KEY_DC:
                    value = value[:position] + value[position + 1:]
                elif key in (curses.KEY_LEFT, "\x02"):
                    position = max(0, position - 1)
                elif key in (curses.KEY_RIGHT, "\x06"):
                    position = min(len(value), position + 1)
                elif key in (curses.KEY_HOME, "\x01"):
                    position = 0
                elif key in (curses.KEY_END, "\x05"):
                    position = len(value)
                elif key == "\x15":
                    value, position = "", 0
                elif isinstance(key, str) and key.isprintable():
                    value = value[:position] + key + value[position:]
                    position += 1
        finally:
            self.cursor(False)

    def run(self, command):
        """Let setup and interactive authentication own the terminal, then restore the UI."""
        curses.def_prog_mode()
        curses.endwin()
        try:
            with subprocess.Popen(command) as process:
                while True:
                    try:
                        code = process.wait()
                        break
                    except KeyboardInterrupt:
                        # The foreground child also received SIGINT. Let its recovery finish.
                        print("\nWaiting for the command to finish cleanup...", flush=True)
            print("\nCommand exit status:", code)
            input("Press Enter to return to Orca setup...")
            return code
        finally:
            curses.reset_prog_mode()
            self.window.keypad(True)
            self.window.clear()
            self.window.refresh()
