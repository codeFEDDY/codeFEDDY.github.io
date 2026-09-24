#!/usr/bin/env python3
"""Compact Quillgeist Lite window-load splash.

Drawn entirely with tkinter so the maintained Clintware eclipse mark appears
consistently on every qq window load without depending on a stale PNG.
"""

from __future__ import annotations

import math
import os
import random
import time

VERSION = "2026.09.24.8"


def main() -> int:
    if os.name != "nt":
        return 0

    try:
        import tkinter as tk

        root = tk.Tk()
        root.configure(bg="black")
        root.overrideredirect(True)
        root.attributes("-topmost", True)

        sw = root.winfo_screenwidth()
        sh = root.winfo_screenheight()

        # Compact by design: large enough to read, small enough to behave like
        # a boot mark rather than taking over the desktop.
        ww = min(500, max(420, int(sw * 0.26)))
        wh = min(340, max(300, int(sh * 0.31)))
        x = max(0, (sw - ww) // 2)
        y = max(0, (sh - wh) // 2)
        root.geometry(f"{ww}x{wh}+{x}+{y}")

        canvas = tk.Canvas(
            root,
            width=ww,
            height=wh,
            bg="black",
            highlightthickness=0,
            borderwidth=0,
        )
        canvas.pack(fill="both", expand=True)

        cx = ww / 2
        cy = wh * 0.47
        rx = min(ww * 0.31, 145)
        ry = min(wh * 0.34, 110)

        random.seed(2026)

        # Layered dotted eclipse halo: electric blue, sparse outside, bright rim.
        layers = [
            (1.15, 96, 1.2, "#003E73"),
            (1.10, 112, 1.4, "#0058A6"),
            (1.055, 132, 1.7, "#0076D8"),
            (1.018, 164, 1.8, "#0B9DFF"),
            (0.995, 190, 1.55, "#31C4FF"),
            (0.965, 150, 1.2, "#0877C5"),
        ]

        for scale, count, dot, color in layers:
            for i in range(count):
                a = (math.tau * i / count) + random.uniform(-0.012, 0.012)
                # Slightly heavier sides/bottom like the reference.
                density = 0.78 + 0.22 * abs(math.sin(a))
                if random.random() > density:
                    continue
                px = cx + math.cos(a) * rx * scale
                py = cy + math.sin(a) * ry * scale
                r = dot + random.uniform(-0.35, 0.55)
                canvas.create_oval(px-r, py-r, px+r, py+r, fill=color, outline="")

        # Fine outer particles to create the airy eclipse edge.
        for i in range(150):
            a = math.tau * i / 150 + random.uniform(-0.018, 0.018)
            spread = random.uniform(1.12, 1.27)
            px = cx + math.cos(a) * rx * spread
            py = cy + math.sin(a) * ry * spread
            r = random.choice((0.7, 0.9, 1.1))
            canvas.create_oval(px-r, py-r, px+r, py+r, fill="#006DB8", outline="")

        # Subtle side streaks from the reference artwork.
        for side in (-1, 1):
            sx = cx + side * rx * 1.10
            for j in range(5):
                yy = cy + (j - 2) * 19
                length = 24 - abs(j - 2) * 3
                ex = sx + side * length
                canvas.create_line(sx, yy, ex, yy, fill="#005A97", width=1)
                canvas.create_oval(ex-1.2, yy-1.2, ex+1.2, yy+1.2, fill="#0089D6", outline="")

        # Center wordmark. Keep it monochrome and restrained exactly as intended.
        family = "Cascadia Mono"
        title_size = max(20, min(28, int(ww / 18)))
        canvas.create_text(
            cx,
            cy - 5,
            text="CLINTWARE",
            fill="#F3F3F3",
            font=(family, title_size, "bold"),
            anchor="center",
        )
        canvas.create_text(
            cx + min(205, ww * 0.31),
            cy - 22,
            text="™",
            fill="#F3F3F3",
            font=(family, max(8, title_size // 4), "bold"),
            anchor="center",
        )
        canvas.create_text(
            cx,
            cy + title_size * 0.92,
            text="EST. 2026",
            fill="#E4E4E4",
            font=(family, max(10, title_size // 3), "bold"),
            anchor="center",
        )

        root.after(1000, root.destroy)
        root.bind("<Escape>", lambda _e: root.destroy())
        root.bind("<Button-1>", lambda _e: root.destroy())
        root.mainloop()
    except Exception:
        # Cosmetic only; qq must still boot if GUI support is unavailable.
        time.sleep(0.10)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
