workers 2
threads 64,64

bind 'tcp://0.0.0.0:5000'
bind 'unix:///run/isubata/puma.sock'

stdout_redirect '/home/isucon/puma.out', '/home/isucon/puma.err', true

# preload_app!
