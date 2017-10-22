#!/bin/bash -e

cd ~/isubata/webapp/ruby/deploy.sh
git pull
mkdir ~/vendor || :
bundle check || bundle install --path ~/vendor/bundle --jobs 300
sudo systemctl restart isubata.ruby
