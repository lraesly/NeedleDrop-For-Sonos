#!/usr/bin/env python3
"""Generate a modern macOS app icon for NeedleDrop — turntable/vinyl theme."""

import math
from PIL import Image, ImageDraw, ImageFilter, ImageFont

SIZE = 1024
# Render at 2x for anti-aliasing, then downscale
RENDER_SIZE = SIZE * 2
CENTER = RENDER_SIZE // 2

def lerp_color(c1, c2, t):
    """Linearly interpolate between two RGB(A) colors."""
    return tuple(int(a + (b - a) * t) for a, b in zip(c1, c2))

def radial_gradient(draw, cx, cy, radius, inner_color, outer_color, img):
    """Draw a radial gradient by plotting pixels."""
    for y in range(max(0, cy - radius), min(img.height, cy + radius + 1)):
        for x in range(max(0, cx - radius), min(img.width, cx + radius + 1)):
            dist = math.sqrt((x - cx) ** 2 + (y - cy) ** 2)
            if dist <= radius:
                t = dist / radius
                color = lerp_color(inner_color, outer_color, t)
                img.putpixel((x, y), color)

def draw_vertical_gradient(img, y_start, y_end, color_top, color_bottom):
    """Draw a vertical linear gradient."""
    draw = ImageDraw.Draw(img)
    for y in range(y_start, y_end):
        t = (y - y_start) / (y_end - y_start)
        color = lerp_color(color_top, color_bottom, t)
        draw.line([(0, y), (img.width, y)], fill=color)

def create_icon():
    # Create base image with transparent background
    # macOS applies the squircle mask automatically
    img = Image.new("RGBA", (RENDER_SIZE, RENDER_SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # === BACKGROUND ===
    # Rich dark gradient background (deep charcoal to near-black)
    bg_top = (45, 40, 55)      # Dark purple-grey
    bg_bottom = (18, 16, 22)   # Near black
    for y in range(RENDER_SIZE):
        t = y / RENDER_SIZE
        # Add slight curve for more dramatic gradient
        t = t * t * 0.6 + t * 0.4
        color = lerp_color(bg_top, bg_bottom, t)
        draw.line([(0, y), (RENDER_SIZE, y)], fill=(*color, 255))

    # === VINYL RECORD ===
    record_cx = CENTER - int(RENDER_SIZE * 0.03)
    record_cy = CENTER + int(RENDER_SIZE * 0.02)
    record_radius = int(RENDER_SIZE * 0.38)

    # Record shadow
    shadow_layer = Image.new("RGBA", (RENDER_SIZE, RENDER_SIZE), (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow_layer)
    shadow_offset = int(RENDER_SIZE * 0.015)
    shadow_draw.ellipse(
        [record_cx - record_radius + shadow_offset,
         record_cy - record_radius + shadow_offset,
         record_cx + record_radius + shadow_offset,
         record_cy + record_radius + shadow_offset],
        fill=(0, 0, 0, 120)
    )
    shadow_layer = shadow_layer.filter(ImageFilter.GaussianBlur(radius=RENDER_SIZE * 0.025))
    img = Image.alpha_composite(img, shadow_layer)
    draw = ImageDraw.Draw(img)

    # Main record body — near-black with subtle warmth
    record_color = (25, 22, 28)
    draw.ellipse(
        [record_cx - record_radius, record_cy - record_radius,
         record_cx + record_radius, record_cy + record_radius],
        fill=(*record_color, 255)
    )

    # Record edge highlight (subtle rim light)
    for i in range(3):
        r = record_radius - i
        opacity = 60 - i * 18
        draw.ellipse(
            [record_cx - r, record_cy - r, record_cx + r, record_cy + r],
            outline=(120, 115, 130, opacity), width=1
        )

    # Vinyl grooves — bold concentric bands for readability at small sizes
    groove_inner = int(record_radius * 0.28)
    groove_outer = int(record_radius * 0.93)
    groove_spacing = 7  # wider spacing so bands survive downscale

    # Draw alternating dark/light groove bands
    for r in range(groove_inner, groove_outer, groove_spacing):
        phase = (r - groove_inner) / (groove_outer - groove_inner)
        # Bold alternating pattern — higher contrast
        band_idx = (r - groove_inner) // groove_spacing
        if band_idx % 2 == 0:
            brightness = 48 + int(12 * math.sin(phase * 40))
            opacity = 130
        else:
            brightness = 28 + int(6 * math.sin(phase * 40))
            opacity = 100
        groove_color = (brightness, brightness - 3, brightness + 5, opacity)
        # Thicker lines so they don't vanish at small sizes
        draw.ellipse(
            [record_cx - r, record_cy - r, record_cx + r, record_cy + r],
            outline=groove_color, width=3
        )

    # "Silent" gaps — wider spacing near label and rim edge
    for gap_r in [int(groove_inner * 1.05), int(groove_outer * 0.97)]:
        draw.ellipse(
            [record_cx - gap_r, record_cy - gap_r,
             record_cx + gap_r, record_cy + gap_r],
            outline=(35, 30, 40, 120), width=5
        )

    # Iridescent light reflection — bold rainbow arc across grooves
    reflection_layer = Image.new("RGBA", (RENDER_SIZE, RENDER_SIZE), (0, 0, 0, 0))
    ref_draw = ImageDraw.Draw(reflection_layer)

    # Primary highlight — wide bright sweep (upper-left quadrant)
    highlight_center_r = int(record_radius * 0.62)
    for dr in range(-60, 61):
        r = highlight_center_r + dr
        if r < groove_inner or r > groove_outer:
            continue
        dist = abs(dr) / 60.0
        # Bell curve falloff
        intensity = math.exp(-dist * dist * 4.0)
        # Rainbow hue shift across the arc for iridescence
        hue_t = (dr + 60) / 120.0
        red = int(80 + 80 * math.sin(hue_t * math.pi * 2.0 + 0.0))
        green = int(80 + 60 * math.sin(hue_t * math.pi * 2.0 + 2.1))
        blue = int(100 + 80 * math.sin(hue_t * math.pi * 2.0 + 4.2))
        opacity = int(55 * intensity)
        ref_draw.arc(
            [record_cx - r, record_cy - r, record_cx + r, record_cy + r],
            start=205, end=315,
            fill=(red, green, blue, opacity), width=4
        )

    # Secondary highlight — opposite side, cooler tone, dimmer
    highlight2_r = int(record_radius * 0.45)
    for dr in range(-35, 36):
        r = highlight2_r + dr
        if r < groove_inner or r > groove_outer:
            continue
        dist = abs(dr) / 35.0
        intensity = math.exp(-dist * dist * 5.0)
        opacity = int(30 * intensity)
        ref_draw.arc(
            [record_cx - r, record_cy - r, record_cx + r, record_cy + r],
            start=40, end=110,
            fill=(120, 140, 180, opacity), width=3
        )

    img = Image.alpha_composite(img, reflection_layer)
    draw = ImageDraw.Draw(img)

    # === CENTER LABEL ===
    label_radius = int(record_radius * 0.22)

    # Label gradient — warm amber/orange
    label_layer = Image.new("RGBA", (RENDER_SIZE, RENDER_SIZE), (0, 0, 0, 0))
    label_draw = ImageDraw.Draw(label_layer)

    # Draw label with gradient
    for r in range(label_radius, 0, -1):
        t = 1.0 - (r / label_radius)
        # Warm amber gradient: outer edge darker, center brighter
        outer_c = (180, 90, 20, 255)    # Deep amber
        inner_c = (240, 170, 50, 255)   # Bright gold
        color = lerp_color(outer_c, inner_c, t)
        label_draw.ellipse(
            [record_cx - r, record_cy - r, record_cx + r, record_cy + r],
            fill=color
        )

    img = Image.alpha_composite(img, label_layer)
    draw = ImageDraw.Draw(img)

    # Label detail — subtle concentric rings on the label
    for r_offset in range(3, label_radius - 5, 8):
        r = label_radius - r_offset
        draw.ellipse(
            [record_cx - r, record_cy - r, record_cx + r, record_cy + r],
            outline=(160, 75, 15, 30), width=1
        )

    # Spindle hole
    spindle_r = int(label_radius * 0.12)
    draw.ellipse(
        [record_cx - spindle_r, record_cy - spindle_r,
         record_cx + spindle_r, record_cy + spindle_r],
        fill=(18, 16, 22, 255)
    )
    # Spindle rim highlight
    draw.ellipse(
        [record_cx - spindle_r, record_cy - spindle_r,
         record_cx + spindle_r, record_cy + spindle_r],
        outline=(80, 75, 85, 180), width=2
    )

    # === TONEARM ===
    arm_layer = Image.new("RGBA", (RENDER_SIZE, RENDER_SIZE), (0, 0, 0, 0))
    arm_draw = ImageDraw.Draw(arm_layer)

    # Tonearm pivot point (upper right area)
    pivot_x = record_cx + int(record_radius * 0.85)
    pivot_y = record_cy - int(record_radius * 0.85)

    # Tonearm extends from pivot down toward the record
    # Calculate angle so needle touches record grooves
    needle_x = record_cx + int(record_radius * 0.55)
    needle_y = record_cy - int(record_radius * 0.10)

    # Arm joint (elbow point)
    joint_x = pivot_x - int(record_radius * 0.10)
    joint_y = pivot_y + int(record_radius * 0.45)

    # Tonearm shadow
    shadow_arm = Image.new("RGBA", (RENDER_SIZE, RENDER_SIZE), (0, 0, 0, 0))
    sa_draw = ImageDraw.Draw(shadow_arm)
    s_off = int(RENDER_SIZE * 0.008)
    sa_draw.line([(pivot_x + s_off, pivot_y + s_off), (joint_x + s_off, joint_y + s_off)],
                 fill=(0, 0, 0, 80), width=int(RENDER_SIZE * 0.012))
    sa_draw.line([(joint_x + s_off, joint_y + s_off), (needle_x + s_off, needle_y + s_off)],
                 fill=(0, 0, 0, 80), width=int(RENDER_SIZE * 0.008))
    shadow_arm = shadow_arm.filter(ImageFilter.GaussianBlur(radius=RENDER_SIZE * 0.008))
    img = Image.alpha_composite(img, shadow_arm)

    # Main arm segment (pivot to joint) — chrome/silver
    arm_width_main = int(RENDER_SIZE * 0.014)
    arm_color = (175, 175, 185, 255)
    arm_highlight = (220, 220, 230, 255)

    arm_draw.line([(pivot_x, pivot_y), (joint_x, joint_y)],
                  fill=arm_color, width=arm_width_main)
    # Highlight edge
    dx = joint_x - pivot_x
    dy = joint_y - pivot_y
    length = math.sqrt(dx * dx + dy * dy)
    nx = -dy / length * 2
    ny = dx / length * 2
    arm_draw.line([(pivot_x + nx, pivot_y + ny), (joint_x + nx, joint_y + ny)],
                  fill=arm_highlight, width=2)

    # Headshell segment (joint to needle) — slightly thinner
    arm_width_head = int(RENDER_SIZE * 0.009)
    arm_draw.line([(joint_x, joint_y), (needle_x, needle_y)],
                  fill=arm_color, width=arm_width_head)

    # Pivot base — metallic circle
    pivot_r = int(RENDER_SIZE * 0.025)
    # Dark base
    arm_draw.ellipse(
        [pivot_x - pivot_r, pivot_y - pivot_r,
         pivot_x + pivot_r, pivot_y + pivot_r],
        fill=(90, 88, 95, 255)
    )
    # Highlight ring
    arm_draw.ellipse(
        [pivot_x - pivot_r, pivot_y - pivot_r,
         pivot_x + pivot_r, pivot_y + pivot_r],
        outline=(160, 158, 168, 200), width=3
    )
    # Center screw
    screw_r = int(pivot_r * 0.35)
    arm_draw.ellipse(
        [pivot_x - screw_r, pivot_y - screw_r,
         pivot_x + screw_r, pivot_y + screw_r],
        fill=(130, 128, 138, 255)
    )

    # Joint circle
    joint_r = int(RENDER_SIZE * 0.010)
    arm_draw.ellipse(
        [joint_x - joint_r, joint_y - joint_r,
         joint_x + joint_r, joint_y + joint_r],
        fill=(140, 138, 148, 255)
    )

    # Cartridge/headshell at needle end — small rectangle
    cart_length = int(RENDER_SIZE * 0.030)
    cart_width = int(RENDER_SIZE * 0.016)
    # Calculate angle of headshell
    hx = needle_x - joint_x
    hy = needle_y - joint_y
    h_angle = math.atan2(hy, hx)

    # Draw cartridge as a rotated rectangle (approximate with polygon)
    cos_a = math.cos(h_angle)
    sin_a = math.sin(h_angle)
    perp_x = -sin_a * cart_width / 2
    perp_y = cos_a * cart_width / 2
    cart_end_x = needle_x + cos_a * cart_length * 0.3
    cart_end_y = needle_y + sin_a * cart_length * 0.3
    cart_start_x = needle_x - cos_a * cart_length * 0.7
    cart_start_y = needle_y - sin_a * cart_length * 0.7

    cart_points = [
        (cart_start_x - perp_x, cart_start_y - perp_y),
        (cart_end_x - perp_x, cart_end_y - perp_y),
        (cart_end_x + perp_x, cart_end_y + perp_y),
        (cart_start_x + perp_x, cart_start_y + perp_y),
    ]
    arm_draw.polygon(cart_points, fill=(60, 58, 65, 255))
    arm_draw.polygon(cart_points, outline=(120, 118, 128, 200))

    # Needle tip — tiny bright point
    needle_tip_r = int(RENDER_SIZE * 0.004)
    arm_draw.ellipse(
        [needle_x - needle_tip_r + int(cos_a * cart_length * 0.35),
         needle_y - needle_tip_r + int(sin_a * cart_length * 0.35),
         needle_x + needle_tip_r + int(cos_a * cart_length * 0.35),
         needle_y + needle_tip_r + int(sin_a * cart_length * 0.35)],
        fill=(230, 220, 200, 255)
    )

    img = Image.alpha_composite(img, arm_layer)
    draw = ImageDraw.Draw(img)

    # === SUBTLE OVERALL VIGNETTE ===
    vignette = Image.new("RGBA", (RENDER_SIZE, RENDER_SIZE), (0, 0, 0, 0))
    vig_draw = ImageDraw.Draw(vignette)
    for r in range(RENDER_SIZE // 2, int(RENDER_SIZE * 0.35), -1):
        t = (r - RENDER_SIZE * 0.35) / (RENDER_SIZE // 2 - RENDER_SIZE * 0.35)
        opacity = int(40 * t * t)
        vig_draw.ellipse(
            [CENTER - r, CENTER - r, CENTER + r, CENTER + r],
            outline=(0, 0, 0, opacity), width=2
        )
    img = Image.alpha_composite(img, vignette)

    # === DOWNSCALE FOR ANTI-ALIASING ===
    img = img.resize((SIZE, SIZE), Image.LANCZOS)

    return img


def main():
    icon = create_icon()

    # Save the main 1024x1024 icon
    output_dir = "NeedleDrop/Resources/Assets.xcassets/AppIcon.appiconset"
    import os
    os.makedirs(output_dir, exist_ok=True)

    icon_path = os.path.join(output_dir, "AppIcon.png")
    icon.save(icon_path, "PNG")
    print(f"Saved {icon_path} ({SIZE}x{SIZE})")

    # Also generate smaller sizes for compatibility
    sizes = [512, 256, 128, 64, 32, 16]
    for s in sizes:
        resized = icon.resize((s, s), Image.LANCZOS)
        path = os.path.join(output_dir, f"AppIcon_{s}x{s}.png")
        resized.save(path, "PNG")
        print(f"Saved {path} ({s}x{s})")

    # Write Contents.json for the asset catalog
    contents = """{
  "images" : [
    {
      "filename" : "AppIcon_16x16.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "16x16"
    },
    {
      "filename" : "AppIcon_32x32.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "16x16"
    },
    {
      "filename" : "AppIcon_32x32.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "32x32"
    },
    {
      "filename" : "AppIcon_64x64.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "32x32"
    },
    {
      "filename" : "AppIcon_128x128.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "128x128"
    },
    {
      "filename" : "AppIcon_256x256.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "128x128"
    },
    {
      "filename" : "AppIcon_256x256.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "256x256"
    },
    {
      "filename" : "AppIcon_512x512.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "256x256"
    },
    {
      "filename" : "AppIcon_512x512.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "512x512"
    },
    {
      "filename" : "AppIcon.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "512x512"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}"""

    contents_path = os.path.join(output_dir, "Contents.json")
    with open(contents_path, "w") as f:
        f.write(contents)
    print(f"Saved {contents_path}")
    print("\nDone! AppIcon.appiconset is ready.")


if __name__ == "__main__":
    main()
