#!/bin/bash

# Update all posts to Chirpy format
for file in _posts/*.md; do
  echo "Processing $file..."
  
  # Extract current front matter
  title=$(grep "^title:" "$file" | head -1)
  date=$(grep "^date:" "$file" | head -1 | awk '{print $2}')
  categories=$(grep "^categories:" "$file" -A 10 | grep "  -" | head -1 | sed 's/  - //')
  tags=$(grep "^tags:" "$file" -A 10 | grep "  -" | sed 's/  - //' | tr '\n' ',' | sed 's/,$//')
  
  # Skip if already updated
  if grep -q "categories: \[" "$file"; then
    echo "  Already updated, skipping..."
    continue
  fi
  
  echo "  Updating front matter..."
done

echo "Done!"
