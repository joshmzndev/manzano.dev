#!/usr/bin/env python3
"""Generate a QR code PNG for a website URL.

Usage:
    python3 qr_gen.py https://example.com
    python3 qr_gen.py https://example.com -o example.png

Requires: pip install "qrcode[pil]"
"""
import argparse
import sys
from urllib.parse import urlparse

try:
    import qrcode
except ImportError:
    sys.exit('Missing dependency: pip install "qrcode[pil]"')


def default_filename(url):
    host = urlparse(url).netloc or "qrcode"
    return f"{host.replace(':', '_')}.png"


def main():
    parser = argparse.ArgumentParser(description="Generate a QR code for a website.")
    parser.add_argument("url", help="Website URL (e.g. https://example.com)")
    parser.add_argument("-o", "--output", help="Output PNG file (default: <domain>.png)")
    parser.add_argument("-s", "--size", type=int, default=10, help="Box size in pixels (default: 10)")
    args = parser.parse_args()

    url = args.url
    if not urlparse(url).scheme:
        url = "https://" + url

    qr = qrcode.QRCode(
        error_correction=qrcode.constants.ERROR_CORRECT_M,
        box_size=args.size,
        border=4,
    )
    qr.add_data(url)
    qr.make(fit=True)

    output = args.output or default_filename(url)
    qr.make_image(fill_color="black", back_color="white").save(output)
    print(f"Saved QR code for {url} -> {output}")


if __name__ == "__main__":
    main()
