#!/bin/bash -ex

cd ~/isubata/proxy

make build

sudo cp isubata.proxy.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl restart isubata.proxy
