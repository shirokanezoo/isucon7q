#!/bin/bash -ex

export PATH=/home/isucon/local/ruby-trunk/bin:$PATH

cd ~/isubata/webapp/ruby/
git pull
mkdir ~/vendor || :
bundle check || bundle install --path ~/vendor/bundle --jobs 300

sudo cp isubata.ruby.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl restart isubata.ruby

sudo bash -c 'echo > /var/log/nginx/access.log; echo > /tmp/isu-query.log; echo > /tmp/isu-rack.log'
