# shellcheck shell=bash
# Manifest parsing. Tool inventories live in manifest/*.tsv; manifest/local/ (git-ignored) is merged on top.

# manifest_rows <file.tsv>: rows of manifest/<file> merged with manifest/local/<file>.
# Comments and blank lines are dropped; a local row replaces the shipped row with the same key
# (first column) in place, and new local keys are appended in order.
manifest_rows() {
  local base="$ORCA_SETUP_MANIFEST_DIR/$1" overlay="$ORCA_SETUP_MANIFEST_DIR/local/$1"
  [ -r "$base" ] || die "manifest file missing: manifest/$1"
  if [ -r "$overlay" ]; then set -- "$base" "$overlay"; else set -- "$base"; fi
  awk -F'\t' '
    /^[[:space:]]*(#|$)/ { next }
    { if (!($1 in row)) order[++n] = $1; row[$1] = $0 }
    END { for (i = 1; i <= n; i++) print row[order[i]] }
  ' "$@"
}

# manifest_column_index <platform>: column holding the install method for that platform.
manifest_column_index() {
  case "$1" in
    macos) echo 4 ;;
    debian) echo 5 ;;
    *) die "no manifest column for platform: $1" ;;
  esac
}

# manifest_select <file.tsv> <platform> <group>: "name<TAB>check<TAB>method" for one group on one platform.
# Rows whose method is "-" (not applicable on that platform) are skipped.
manifest_select() {
  local column
  column=$(manifest_column_index "$2")
  manifest_rows "$1" | awk -F'\t' -v OFS='\t' -v col="$column" -v group="$3" '
    $3 == group && $col != "-" && $col != "" { print $1, $2, $col }
  '
}

# manifest_groups <file.tsv>: the distinct groups in a manifest, in order of appearance.
manifest_groups() {
  manifest_rows "$1" | awk -F'\t' '!seen[$3]++ { print $3 }'
}

# skills_for <platform>: "targets<TAB>skill skill ..." lines, one per distinct install-target list.
skills_for() {
  manifest_rows orca-skills.tsv | awk -F'\t' -v platform="$1" '
    ("," $2 ",") ~ ("," platform ",") {
      if (!($3 in skills)) order[++n] = $3
      skills[$3] = skills[$3] (skills[$3] == "" ? "" : " ") $1
    }
    END { for (i = 1; i <= n; i++) print order[i] "\t" skills[order[i]] }
  '
}
