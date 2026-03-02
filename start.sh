#!/bin/bash
export HOME=/home/hermes
export ASDF_DATA_DIR=/home/hermes/.asdf
export PATH="/home/hermes/.asdf/shims:/home/hermes/.asdf/bin:$PATH"
. /home/hermes/.asdf/asdf.sh
cd /home/hermes/services/toscanini
exec mix phx.server
