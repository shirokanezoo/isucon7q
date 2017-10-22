workers 2
if Socket.gethostname == 'app0213'
  threads 32,64
else
  threads 32,32
end

bind 'tcp://0.0.0.0:5000'
bind 'unix:///run/isubata/puma.sock?backlog=2048'

stdout_redirect '/home/isucon/puma.out', '/home/isucon/puma.err', true

# preload_app!
