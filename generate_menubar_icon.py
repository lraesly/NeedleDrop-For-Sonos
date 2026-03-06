#!/usr/bin/env python3
"""Generate menu bar template icons for NeedleDrop."""

import math
from PIL import Image, ImageDraw

def create_menubar_icon(size):
    """Create a menu bar template icon at the given pixel size.

    Template images: black shapes on transparent background.
    macOS automatically tints them for light/dark mode.
    """
    # Render at 4x then downscale for clean anti-aliasing
    render = size * 4
    center = render // 2
    img = Image.new("RGBA", (render, render), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Padding from edges
    pad = render * 0.08
    available = render - pad * 2

    # Record disc — slightly left of center to make room for tonearm
    record_cx = int(center - available * 0.06)
    record_cy = int(center + available * 0.02)
    record_r = int(available * 0.40)

    # Main disc
    draw.ellipse(
        [record_cx - record_r, record_cy - record_r,
         record_cx + record_r, record_cy + record_r],
        fill=(0, 0, 0, 255)
    )

    # Groove rings — a few visible concentric lines cut out slightly
    for ring_frac in [0.55, 0.70, 0.85]:
        r = int(record_r * ring_frac)
        draw.ellipse(
            [record_cx - r, record_cy - r, record_cx + r, record_cy + r],
            outline=(0, 0, 0, 100), width=max(1, render // 40)
        )
        # Cut a thin transparent ring to show groove gap
        r_gap = r + 1
        draw.ellipse(
            [record_cx - r_gap, record_cy - r_gap,
             record_cx + r_gap, record_cy + r_gap],
            outline=(0, 0, 0, 160), width=1
        )

    # Center label area — lighter circle (partially transparent for template contrast)
    label_r = int(record_r * 0.28)
    draw.ellipse(
        [record_cx - label_r, record_cy - label_r,
         record_cx + label_r, record_cy + label_r],
        fill=(0, 0, 0, 140)
    )

    # Spindle hole
    hole_r = max(2, int(record_r * 0.08))
    draw.ellipse(
        [record_cx - hole_r, record_cy - hole_r,
         record_cx + hole_r, record_cy + hole_r],
        fill=(0, 0, 0, 0)
    )

    # === TONEARM ===
    # Pivot in upper-right
    pivot_x = int(record_cx + record_r * 0.80)
    pivot_y = int(record_cy - record_r * 0.80)

    # Needle touches record at ~60% radius from center
    needle_x = int(record_cx + record_r * 0.48)
    needle_y = int(record_cy - record_r * 0.08)

    # Arm segments
    arm_width = max(2, render // 24)
    head_width = max(1, render // 32)

    # Joint point
    joint_x = int(pivot_x - record_r * 0.05)
    joint_y = int(pivot_y + record_r * 0.40)

    # Main arm (pivot to joint)
    draw.line([(pivot_x, pivot_y), (joint_x, joint_y)],
              fill=(0, 0, 0, 255), width=arm_width)

    # Headshell (joint to needle)
    draw.line([(joint_x, joint_y), (needle_x, needle_y)],
              fill=(0, 0, 0, 255), width=head_width)

    # Pivot dot
    pivot_r = max(2, render // 18)
    draw.ellipse(
        [pivot_x - pivot_r, pivot_y - pivot_r,
         pivot_x + pivot_r, pivot_y + pivot_r],
        fill=(0, 0, 0, 255)
    )

    # Cartridge — small rectangle at needle end
    hx = needle_x - joint_x
    hy = needle_y - joint_y
    h_len = math.sqrt(hx * hx + hy * hy)
    if h_len > 0:
        ux, uy = hx / h_len, hy / h_len
        px, py = -uy, ux  # perpendicular
        cart_len = max(3, render // 16)
        cart_w = max(2, render // 28)
        cx_start = needle_x - ux * cart_len * 0.4
        cy_start = needle_y - uy * cart_len * 0.4
        cx_end = needle_x + ux * cart_len * 0.6
        cy_end = needle_y + uy * cart_len * 0.6
        hw = cart_w / 2
        points = [
            (cx_start - px * hw, cy_start - py * hw),
            (cx_end - px * hw, cy_end - py * hw),
            (cx_end + px * hw, cy_end + py * hw),
            (cx_start + px * hw, cy_start + py * hw),
        ]
        draw.polygon(points, fill=(0, 0, 0, 255))

    # Downscale
    img = img.resize((size, size), Image.LANCZOS)
    return img


def create_disconnected_icon(size):
    """Create disconnected variant — record with a diagonal slash."""
    img = create_menubar_icon(size)
    draw = ImageDraw.Draw(img)

    # Diagonal slash line across the icon
    margin = int(size * 0.15)
    line_width = max(1, size // 12)

    # Draw white outline for the slash (knockout)
    draw.line(
        [(margin, margin), (size - margin, size - margin)],
        fill=(0, 0, 0, 0), width=line_width + 2
    )
    # Draw the slash
    draw.line(
        [(margin, margin), (size - margin, size - margin)],
        fill=(0, 0, 0, 220), width=line_width
    )

    return img


def main():
    import os

    # Connected icon
    icon_dir = "NeedleDrop/Resources/Assets.xcassets/MenuBarIcon.imageset"
    for size, suffix in [(18, ""), (36, "@2x"), (54, "@3x")]:
        icon = create_menubar_icon(size)
        path = os.path.join(icon_dir, f"MenuBarIcon{suffix}.png")
        icon.save(path, "PNG")
        print(f"Saved {path} ({size}x{size})")

    # Disconnected icon
    disc_dir = "NeedleDrop/Resources/Assets.xcassets/MenuBarIconDisconnected.imageset"
    for size, suffix in [(18, ""), (36, "@2x"), (54, "@3x")]:
        icon = create_disconnected_icon(size)
        path = os.path.join(disc_dir, f"MenuBarIconDisconnected{suffix}.png")
        icon.save(path, "PNG")
        print(f"Saved {path} ({size}x{size})")

    print("\nDone! Menu bar icons updated.")


if __name__ == "__main__":
    main()
