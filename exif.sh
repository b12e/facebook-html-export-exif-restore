#!/bin/bash

# Facebook HTML Export EXIF Restoration Script
# This script extracts timestamps from Facebook HTML export files and adds them as EXIF data

# Check if required tools are installed
check_dependencies() {
    local missing_deps=()
    
    if ! command -v exiftool &> /dev/null; then
        missing_deps+=("exiftool")
    fi
    
    if ! command -v python3 &> /dev/null; then
        missing_deps+=("python3")
    fi
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo "Error: Missing required dependencies: ${missing_deps[*]}"
        echo ""
        echo "Please install:"
        echo "  exiftool:"
        echo "    Ubuntu/Debian: sudo apt-get install libimage-exiftool-perl"
        echo "    macOS: brew install exiftool"
        echo "    RHEL/CentOS: sudo yum install perl-Image-ExifTool"
        echo "  python3:"
        echo "    Ubuntu/Debian: sudo apt-get install python3"
        echo "    macOS: brew install python3"
        exit 1
    fi
}

# Create Python script for HTML parsing
create_parser_script() {
    cat > /tmp/fb_html_parser.py << 'EOF'
#!/usr/bin/env python3
import sys
import re
from html.parser import HTMLParser
from datetime import datetime
import locale
import json

class FacebookPhotoParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.photos = {}
        self.current_photo = None
        self.current_timestamp = None
        self.in_timestamp_div = False
        self.capture_timestamp = False
        
    def handle_starttag(self, tag, attrs):
        attrs_dict = dict(attrs)
        
        # Look for photo links
        if tag == 'a':
            href = attrs_dict.get('href', '')
            # Check if this is a photo link
            if '.jpg' in href or '.png' in href or '.mp4' in href:
                # Extract just the filename
                self.current_photo = href.split('/')[-1]
        
        # Look for timestamp divs (class="_3-94 _2lem")
        if tag == 'div':
            class_attr = attrs_dict.get('class', '')
            if '_2lem' in class_attr:
                self.in_timestamp_div = True
                self.capture_timestamp = True
    
    def handle_endtag(self, tag):
        if tag == 'div' and self.in_timestamp_div:
            self.in_timestamp_div = False
            if self.current_photo and self.current_timestamp:
                self.photos[self.current_photo] = self.current_timestamp
                self.current_photo = None
                self.current_timestamp = None
    
    def handle_data(self, data):
        if self.capture_timestamp and self.in_timestamp_div:
            # Try to parse various date formats
            data = data.strip()
            if data:
                # Try Dutch format first (e.g., "18 mei 2012 16:09")
                timestamp = self.parse_dutch_date(data)
                if not timestamp:
                    # Try English format
                    timestamp = self.parse_english_date(data)
                
                if timestamp:
                    self.current_timestamp = timestamp
                    self.capture_timestamp = False
    
    def parse_dutch_date(self, date_str):
        dutch_months = {
            'januari': 1, 'februari': 2, 'maart': 3, 'april': 4,
            'mei': 5, 'juni': 6, 'juli': 7, 'augustus': 8,
            'september': 9, 'oktober': 10, 'november': 11, 'december': 12
        }
        
        # Pattern: "18 mei 2012 16:09"
        pattern = r'(\d+)\s+(\w+)\s+(\d{4})\s+(\d+):(\d+)'
        match = re.match(pattern, date_str)
        
        if match:
            day = int(match.group(1))
            month_name = match.group(2).lower()
            year = int(match.group(3))
            hour = int(match.group(4))
            minute = int(match.group(5))
            
            if month_name in dutch_months:
                month = dutch_months[month_name]
                try:
                    dt = datetime(year, month, day, hour, minute)
                    return dt.strftime("%Y:%m:%d %H:%M:%S")
                except:
                    pass
        return None
    
    def parse_english_date(self, date_str):
        # Try various English date formats
        formats = [
            "%B %d, %Y at %I:%M%p",  # "May 18, 2012 at 4:09PM"
            "%B %d, %Y %I:%M%p",      # "May 18, 2012 4:09PM"
            "%d %B %Y %H:%M",         # "18 May 2012 16:09"
            "%Y-%m-%d %H:%M:%S",      # "2012-05-18 16:09:00"
        ]
        
        for fmt in formats:
            try:
                dt = datetime.strptime(date_str, fmt)
                return dt.strftime("%Y:%m:%d %H:%M:%S")
            except:
                continue
        return None

def parse_html_file(filepath):
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()
    
    parser = FacebookPhotoParser()
    parser.feed(content)
    
    return parser.photos

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python3 fb_html_parser.py <html_file>")
        sys.exit(1)
    
    photos = parse_html_file(sys.argv[1])
    print(json.dumps(photos))
EOF
    chmod +x /tmp/fb_html_parser.py
}

# Process a single photo with EXIF data
add_exif_to_photo() {
    local photo_path="$1"
    local timestamp="$2"
    
    if [ ! -f "$photo_path" ]; then
        echo "  ⚠ File not found: $photo_path"
        return 1
    fi
    
    echo "  Adding EXIF to: $(basename "$photo_path")"
    echo "    Timestamp: $timestamp"
    
    # Add EXIF data
    exiftool -overwrite_original \
        -DateTimeOriginal="$timestamp" \
        -CreateDate="$timestamp" \
        -ModifyDate="$timestamp" \
        "$photo_path" > /dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        echo "    ✓ Success"
        return 0
    else
        echo "    ⚠ Failed to add EXIF data"
        return 1
    fi
}

# Main processing function
process_facebook_export() {
    local base_dir="$1"
    
    echo "Processing Facebook export in: $base_dir"
    echo "================================"
    
    # Statistics
    local total_photos=0
    local processed_photos=0
    local failed_photos=0
    
    # Find all HTML files
    echo "Searching for HTML files..."
    
    # Process the main your_photos.html if it exists
    if [ -f "$base_dir/your_photos.html" ]; then
        echo "Processing main album index..."
        local photo_data=$(python3 /tmp/fb_html_parser.py "$base_dir/your_photos.html" 2>/dev/null)
        
        if [ -n "$photo_data" ] && [ "$photo_data" != "{}" ]; then
            echo "Found timestamps in main index"
            
            # Process each photo
            echo "$photo_data" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
for filename, timestamp in data.items():
    print(f'{filename}|{timestamp}')
" | while IFS='|' read -r filename timestamp; do
                ((total_photos++))
                
                # Search for the actual photo file
                photo_path=$(find "$base_dir" -name "$filename" -type f 2>/dev/null | head -1)
                
                if [ -n "$photo_path" ]; then
                    if add_exif_to_photo "$photo_path" "$timestamp"; then
                        ((processed_photos++))
                    else
                        ((failed_photos++))
                    fi
                else
                    echo "  ⚠ Could not find file: $filename"
                    ((failed_photos++))
                fi
            done
        fi
    fi
    
    # Process album HTML files
    for html_file in "$base_dir"/*.html "$base_dir"/album/*.html "$base_dir"/photos_and_videos/album/*.html; do
        if [ -f "$html_file" ]; then
            echo ""
            echo "Processing: $(basename "$html_file")"
            
            # Parse HTML to get photo-timestamp mappings
            local photo_data=$(python3 /tmp/fb_html_parser.py "$html_file" 2>/dev/null)
            
            if [ -n "$photo_data" ] && [ "$photo_data" != "{}" ]; then
                # Process each photo
                echo "$photo_data" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
for filename, timestamp in data.items():
    print(f'{filename}|{timestamp}')
" | while IFS='|' read -r filename timestamp; do
                    ((total_photos++))
                    
                    # Search for the actual photo file
                    # Look in common locations
                    photo_path=""
                    for search_dir in "$base_dir" "$base_dir/photos_and_videos" "$(dirname "$html_file")"; do
                        found=$(find "$search_dir" -name "$filename" -type f 2>/dev/null | head -1)
                        if [ -n "$found" ]; then
                            photo_path="$found"
                            break
                        fi
                    done
                    
                    if [ -n "$photo_path" ]; then
                        if add_exif_to_photo "$photo_path" "$timestamp"; then
                            ((processed_photos++))
                        else
                            ((failed_photos++))
                        fi
                    else
                        echo "  ⚠ Could not find file: $filename"
                        ((failed_photos++))
                    fi
                done
            else
                echo "  No photo timestamps found in this file"
            fi
        fi
    done
    
    # Read final stats
    read total_photos processed_photos failed_photos < "$stats_file"
    
    # Summary
    echo ""
    echo "================================"
    echo "Processing complete!"
    echo "  Total photos found: $total_photos"
    echo "  Successfully processed: $processed_photos"
    echo "  Failed: $failed_photos"
    
    # Cleanup temp file
    rm -f "$stats_file"
}

# Parse command line arguments
DIRECTORY="${1:-.}"
BACKUP=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -b|--backup)
            BACKUP=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS] [DIRECTORY]"
            echo ""
            echo "Restores EXIF timestamps to Facebook photos using HTML export metadata"
            echo ""
            echo "Options:"
            echo "  -b, --backup     Create backup of original files before processing"
            echo "  -h, --help       Show this help message"
            echo ""
            echo "Directory structure expected:"
            echo "  your_photos.html or similar HTML files with photo metadata"
            echo "  photos_and_videos/ folder with actual image files"
            echo ""
            echo "If no directory is specified, current directory is used."
            exit 0
            ;;
        *)
            DIRECTORY="$1"
            shift
            ;;
    esac
done

# Check dependencies
check_dependencies

# Create parser script
create_parser_script

# Create backup if requested
if [ "$BACKUP" = true ]; then
    BACKUP_DIR="${DIRECTORY}/backup_$(date +%Y%m%d_%H%M%S)"
    echo "Creating backup in: $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    
    # Copy all image and video files
    find "$DIRECTORY" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.mp4" -o -iname "*.mov" -o -iname "*.avi" \) -exec cp --parents {} "$BACKUP_DIR" \; 2>/dev/null
    echo "Backup complete"
    echo ""
fi

# Process the export
process_facebook_export "$DIRECTORY"

# Cleanup
rm -f /tmp/fb_html_parser.py