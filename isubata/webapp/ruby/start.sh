#!/bin/bash
cd "$(dirname $0)"
export PATH=/home/isucon/local/ruby-trunk/bin:$PATH
exec bundle exec puma -C ./puma.conf.rb
