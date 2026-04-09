#!/bin/sh
# Use Homebrew's GNU make instead of the system's ancient make 3.81
export THEOS=/Users/thijsmussig/theos
exec /opt/homebrew/opt/make/libexec/gnubin/make "$@"
