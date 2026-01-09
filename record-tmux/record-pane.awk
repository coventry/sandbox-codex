# Prefix each minute with a timestamp header, pass through pane output, and keep writes flushed.
{
  now = strftime("%Y-%m-%d %H:%M")
  if (now != last_min) {
    printf "--- %s ---\n", strftime("%Y-%m-%d %H:%M")
    last_min = now
    fflush("")
  }
  print $0
  fflush("")
}
