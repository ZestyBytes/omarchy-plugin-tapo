#!/bin/sh
# Run a stream consumer and remove its credential-bearing input file when
# the process exits for any reason. The file path itself contains no secret.
secret_file=$1
shift
trap 'rm -f -- "$secret_file"' EXIT HUP INT TERM
"$@"
