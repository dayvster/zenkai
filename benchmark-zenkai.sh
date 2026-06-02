#!/usr/bin/env bash

APP="./zig-out/bin/zenkai"
RUNS=10
WARMUP=2

echo "Benchmarking Zenkai startup time (until window appears)..."
echo "Running $RUNS times after $WARMUP warmups..."

times=()

for ((i = 1; i <= WARMUP + RUNS; i++)); do
  echo -n "Run $i/$((WARMUP + RUNS))... "

  # Start timing
  start=$(date +%s.%N)

  # Launch the app in background
  $APP &
  pid=$!

  # Wait until the window appears (max 15 seconds)
  timeout=15
  while [ $timeout -gt 0 ]; do
    if xwininfo -root -tree 2>/dev/null | grep -q "zenkai"; then
      break
    fi
    sleep 0.05
    ((timeout--))
  done

  end=$(date +%s.%N)
  duration=$(awk "BEGIN {print $end - $start}")

  # Kill the app after measurement
  kill $pid 2>/dev/null
  wait $pid 2>/dev/null

  if [ $i -gt $WARMUP ]; then
    times+=($duration)
    printf " %.3f s\n" "$duration"
  else
    echo "warmup"
  fi
done

# Calculate statistics
awk '
BEGIN {sum=0; min=999; max=0}
{
    sum += $1
    if ($1 < min) min=$1
    if ($1 > max) max=$1
}
END {
    print "\n=== Results ==="
    print "Average: " sum/NR " seconds"
    print "Min:     " min " seconds"
    print "Max:     " max " seconds"
    print "Runs:    " NR
}' <(printf "%s\n" "${times[@]}")
