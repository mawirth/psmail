"""Pixelate sensitive regions in email screenshots."""
from pathlib import Path
import sys

from PIL import Image
import numpy as np


# Configuration
INPUT_FILE = "email.jpg"
OUTPUT_FILE = "email_pixelated.jpg"
PIXEL_SIZE = 15
QUALITY = 95

# Region definitions (x1, y1, x2, y2)
# Adjusted for image size: 1998x1062
# Only pixelate email addresses and subject content, not headers
FROM_COLUMN = (539, 145, 875, 400)  # Email addresses only (all 6 rows)
SUBJECT_COLUMN = (895, 145, 1998, 400)  # Subject lines only (all 6 rows)


def pixelate_region(img_array, x1, y1, x2, y2, pixel_size=10):
    """Pixelate a specific region of the image.
    
    Args:
        img_array: NumPy array representing the image
        x1, y1: Top-left coordinates of the region
        x2, y2: Bottom-right coordinates of the region
        pixel_size: Size of pixelation blocks (default: 10)
    
    Returns:
        Modified image array with pixelated region
    """
    region = img_array[y1:y2, x1:x2]
    height, width = region.shape[:2]
    
    # Calculate downscaled dimensions
    temp_height = max(1, height // pixel_size)
    temp_width = max(1, width // pixel_size)
    
    # Apply pixelation by downscaling and upscaling
    region_img = Image.fromarray(region)
    small = region_img.resize(
        (temp_width, temp_height), Image.NEAREST
    )
    pixelated = small.resize((width, height), Image.NEAREST)
    
    # Replace the region with pixelated version
    img_array[y1:y2, x1:x2] = np.array(pixelated)
    
    return img_array


def process_image(input_path, output_path, regions, pixel_size):
    """Load image, pixelate specified regions, and save result.
    
    Args:
        input_path: Path to input image
        output_path: Path to save processed image
        regions: List of (x1, y1, x2, y2) tuples defining regions
        pixel_size: Size of pixelation blocks
    """
    # Load image
    img = Image.open(input_path)
    img_array = np.array(img)
    
    # Pixelate each region
    for x1, y1, x2, y2 in regions:
        img_array = pixelate_region(
            img_array, x1, y1, x2, y2, pixel_size
        )
    
    # Save result
    result_img = Image.fromarray(img_array)
    result_img.save(output_path, quality=QUALITY)
    
    return output_path


def main():
    """Main entry point."""
    input_file = Path(INPUT_FILE)
    
    if not input_file.exists():
        print(f"Error: Input file '{INPUT_FILE}' not found.")
        sys.exit(1)
    
    regions = [FROM_COLUMN, SUBJECT_COLUMN]
    
    try:
        output_path = process_image(
            INPUT_FILE, OUTPUT_FILE, regions, PIXEL_SIZE
        )
        print(f"Successfully processed image: {output_path}")
    except Exception as e:
        print(f"Error processing image: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
