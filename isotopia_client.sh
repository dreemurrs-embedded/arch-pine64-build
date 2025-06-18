#!/bin/sh

# Build client for https://github.com/catacombing/isotopia job control server.

api="https://catacombing.org/isotopia"

while true; do
    # Wait before checking for new jobs.
    sleep 60

    # Get the next pending job.
    echo "Checking for pending jobs…"
    job=$(curl -sf "$api/pending" | jq -c '.[0]') || exit
    if [[ "$job" == "null" ]]; then
        continue;
    fi

    # Get job attributes.
    packages=$(echo "$job" | jq -r '.packages')
    device=$(echo "$job" | jq -r '.device')
    md5sum=$(echo "$job" | jq -r '.md5sum')
    echo "Found new pending job: $md5sum"

    # Notify jobserver we'd like to build this job.
    #
    # This will fail when a racing condition caused a different builder to pick
    # up the same job.
    curl -fX PUT --json '"building"' "$api/requests/$device/$md5sum/status" || continue
    echo "Starting build of $md5sum…"

    # Build the image.
    ./build.sh -a aarch64 -d "$device" -p "$packages" || continue
    echo "Finished build of $md5sum"

    # Upload the built image.
    alarm_md5sum=$(md5sum ./build/ArchLinuxARM* | awk '{print $1}')
    filename="alarm-$device-$alarm_md5sum-$md5sum.img.xz"
    if [ -f "./build/$filename" ]; then
        curl -fX POST -F filename=@"./build/$filename" "$api/requests/$device/$md5sum/$alarm_md5sum/image" || continue
        echo "Finished upload of $md5sum"
    else
        echo "Built image $filename does not exist"
    fi
done
