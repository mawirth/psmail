# HTML Footer Tool

## Overview

This tool creates an HTML footer with inline logo for your emails. When `data/footer.html` exists, all new emails are automatically sent as HTML instead of plain text.

## Features

- **Rich text footer** with formatting and links
- **Inline logo** embedded as data URI (no separate attachment)
- **Automatic conversion**: Plain text body from neovim → HTML email
- **Easy toggle**: Delete `footer.html` to switch back to plain text

## Usage

### Create HTML Footer

```powershell
.\tools\Create-HtmlFooter.ps1 `
    -Name "Your Name" `
    -Title "Your Title" `
    -Email "your@email.com" `
    -Website "https://yourwebsite.com" `
    -LogoPath "path\to\logo.png"
```

**Parameters:**
- `-Name` (required): Your full name
- `-Title` (optional): Your job title
- `-Email` (optional): Your email address
- `-Website` (optional): Your website URL
- `-LogoPath` (optional): Path to logo image (PNG, JPG, GIF, SVG)

### Examples

**Basic footer without logo:**
```powershell
.\tools\Create-HtmlFooter.ps1 -Name "John Doe"
```

**Full footer with logo:**
```powershell
.\tools\Create-HtmlFooter.ps1 `
    -Name "Jane Smith" `
    -Title "Senior Developer" `
    -Email "jane@example.com" `
    -Website "https://jane.dev" `
    -LogoPath "C:\images\company-logo.png"
```

**With relative paths:**
```powershell
.\tools\Create-HtmlFooter.ps1 `
    -Name "Company Name" `
    -LogoPath ".\logo.png"
```

## How It Works

### Email Composition Workflow

1. **You write in plain text** (in neovim as always)
2. **psmail converts to HTML** automatically
3. **HTML footer is appended** with your logo
4. **Email sent as HTML** with inline images

### Switching Between Text and HTML

**To use HTML emails:**
```powershell
# Create the HTML footer
.\tools\Create-HtmlFooter.ps1 -Name "Your Name" -LogoPath "logo.png"
```

**To switch back to text emails:**
```powershell
# Delete or rename the HTML footer
Remove-Item data\footer.html
```

## Logo Guidelines

### Recommended Specifications

- **Format**: PNG (best) or JPG
- **Size**: Under 50 KB (will warn if over 100 KB)
- **Dimensions**: 120-200 pixels wide
- **Transparency**: PNG with transparent background works best

### Why Data URI?

The logo is embedded directly in the email as Base64-encoded data. This means:
- ✅ No broken images (logo is always included)
- ✅ No external dependencies
- ✅ Works in all email clients
- ⚠️ Slightly increases email size

### Optimize Your Logo

**Use online tools to compress:**
- TinyPNG (https://tinypng.com)
- Squoosh (https://squoosh.app)

**Or use PowerShell:**
```powershell
# Resize with ImageMagick
magick logo.png -resize 150x logo-small.png
```

## HTML Footer Format

The generated `data/footer.html` looks like this:

```html
<div style="margin-top: 20px; padding-top: 10px; border-top: 1px solid #ccc;">
  <p style="margin: 0; font-family: Arial, sans-serif; font-size: 14px; color: #333;">
    <strong>Your Name</strong><br>
    Your Title<br>
    📧 <a href="mailto:your@email.com" style="color: #0066cc;">your@email.com</a><br>
    🌐 <a href="https://yourwebsite.com" style="color: #0066cc;">yourwebsite.com</a>
  </p>
  <img src="data:image/png;base64,iVBORw0KG..." 
       alt="Logo" 
       width="120" 
       style="margin-top: 10px; display: block;">
</div>
```

You can manually edit this file to customize styling.

## Manual Customization

### Edit the HTML Footer

```powershell
# Open in your preferred editor
notepad data\footer.html
# or
code data\footer.html
```

### Custom Styling Examples

**Change text color:**
```html
<p style="color: #555;">
```

**Larger logo:**
```html
<img src="..." width="200">
```

**Add social media icons:**
```html
<a href="https://linkedin.com/in/yourprofile">
  <img src="data:image/png;base64,..." width="24" alt="LinkedIn">
</a>
```

## Troubleshooting

### Logo Not Showing

**Check file path:**
```powershell
Test-Path "path\to\logo.png"
```

**Try absolute path:**
```powershell
.\tools\Create-HtmlFooter.ps1 -Name "Name" -LogoPath "C:\full\path\to\logo.png"
```

### Email Not Sent as HTML

**Verify footer.html exists:**
```powershell
Test-Path data\footer.html
```

**Check for errors:**
- Open psmail with verbose mode
- Look for "Warning: Could not read HTML footer"

### Logo Too Large

**Warning appears if logo > 100 KB:**
```
Warning: Logo is large (156.3 KB). Consider using a smaller image.
```

**Solution:**
- Compress the image
- Resize to smaller dimensions
- Convert to optimized PNG

## Advanced Usage

### Multiple Logos

Include multiple images in your footer:

```html
<div>
  <img src="data:image/png;base64,..." width="100" alt="Company">
  <img src="data:image/png;base64,..." width="80" alt="Certification">
</div>
```

### Conditional Footers

Create multiple footer files:
- `footer.html` - Default
- `footer-formal.html` - Formal business
- `footer-casual.html` - Casual

Switch by renaming the active one.

### Styled Text

Add more HTML styling:

```html
<p style="margin: 5px 0; padding: 10px; background: #f5f5f5; border-left: 3px solid #0066cc;">
  <em>This is a quote or notice in your footer</em>
</p>
```

## Technical Details

### Text to HTML Conversion

psmail automatically:
1. HTML-encodes special characters (`<`, `>`, `&`)
2. Converts line breaks to `<br>`
3. Converts paragraphs (double line breaks) to `<p>` tags
4. Appends HTML footer

### Email Compatibility

The generated HTML is compatible with all major email clients:
- ✅ Outlook
- ✅ Gmail
- ✅ Apple Mail
- ✅ Thunderbird
- ✅ Mobile clients (iOS Mail, Gmail app, etc.)

### Plain Text Recipients

If a recipient's email client doesn't support HTML, they'll see:
- Plain text version of your email
- Footer text without styling/logo

(Graph API automatically creates multipart/alternative emails)

---

**Happy emailing with style!** 🎨
