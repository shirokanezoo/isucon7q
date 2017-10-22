workers 2
threads 32,32

bind 'tcp://0.0.0.0:5000'
bind 'unix:///tmp/puma.sock'

preload_app!
