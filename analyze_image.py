"""Analyze email.jpg to find exact region coordinates."""
from PIL import Image

img = Image.open("email.jpg")
print(f"Image dimensions: {img.size[0]}x{img.size[1]} (width x height)")
print("\nSuggested regions (you can adjust based on visual inspection):")
print(f"Image size: width={img.size[0]}, height={img.size[1]}")
