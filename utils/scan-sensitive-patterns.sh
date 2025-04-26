#!/bin/bash
# search.sh - Search recursively for patterns sourced from /etc/secrets/.ignore
# Usage: ./search.sh [directory]

# Default values
DIRECTORY="${1:-.}"                # Default to current directory if not specified
FOUND=0
PATTERN_FILE="/etc/secrets/.ignore"  # External pattern file

# Check if pattern file exists
if [ ! -f "$PATTERN_FILE" ]; then
  echo "Error: Pattern file $PATTERN_FILE not found."
  exit 1
fi

# Read patterns from the external file
PATTERNS=()
TOTAL_PATTERNS=0

# Read patterns from the pattern file
while IFS= read -r pattern || [ -n "$pattern" ]; do
  # Skip comments and empty lines
  if [[ "$pattern" =~ ^[[:space:]]*$ || "$pattern" =~ ^[[:space:]]*\# ]]; then
    continue
  fi
  
  # Trim whitespace
  pattern=$(echo "$pattern" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  
  if [ -n "$pattern" ]; then
    PATTERNS+=("$pattern")
    TOTAL_PATTERNS=$((TOTAL_PATTERNS + 1))
  fi
done < "$PATTERN_FILE"

# Get list of files, dynamically excluding patterns from .gitignore
GITIGNORE_FILE=".gitignore"
FIND_EXCLUDES=("-not" "-path" "*/\.git/*")

# Dynamically build exclusion list from .gitignore if it exists
if [ -f "$GITIGNORE_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    # Skip comments and empty lines
    if [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*\# ]]; then
      continue
    fi
    
    # Skip negated patterns (lines starting with !)
    if [[ "$line" == !* ]]; then
      continue
    fi
    
    # Trim whitespace
    line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    if [ -n "$line" ]; then
      # Handle different pattern types
      if [[ "$line" == *"/"* ]]; then
        # Pattern with path separator (use -path or -wholename)
        FIND_EXCLUDES+=("-not" "-wholename" "*$line*")
      elif [[ "$line" == "."* ]]; then
        # Hidden files pattern (e.g., .*)
        if [[ "$line" == ".*" ]]; then
          FIND_EXCLUDES+=("-not" "-path" "*/\.*")
        else
          FIND_EXCLUDES+=("-not" "-name" "$line")
        fi
      elif [[ "$line" == *"*"* ]]; then
        # File pattern with wildcard (e.g., *.iso, **/*.runtime)
        if [[ "$line" == *"**/"* ]]; then
          # Extract the filename pattern after **/
          pattern="${line#**/}"
          FIND_EXCLUDES+=("-not" "-name" "$pattern")
        else
          FIND_EXCLUDES+=("-not" "-name" "$line")
        fi
      else
        # Simple file pattern
        FIND_EXCLUDES+=("-not" "-name" "$line")
      fi
    fi
  done < "$GITIGNORE_FILE"
fi

# Build and execute the find command
FILES=$(find "$DIRECTORY" -type f "${FIND_EXCLUDES[@]}" | sort)

# Process each pattern
for pattern in "${PATTERNS[@]}"; do
  PATTERN_FOUND=false
  
  # Process each file for this pattern
  for file in $FILES; do
    if [ -f "$file" ] && grep -q "$pattern" "$file" 2>/dev/null; then
      if [ "$PATTERN_FOUND" = false ]; then
        echo -e "\nMatches for: \"$pattern\""
        PATTERN_FOUND=true
        FOUND=$((FOUND + 1))
      fi
      
      # Print the file and matching lines
      echo -e "\n--- File: $file ---"
      grep --color=always "$pattern" "$file" 2>/dev/null
    fi
  done
done

# Print summary
if [ $FOUND -gt 0 ]; then
  echo -e "\n======================================================"
  echo "Summary: Found matches for $FOUND out of $TOTAL_PATTERNS patterns."
else
  echo "No matches found for any patterns."
fi